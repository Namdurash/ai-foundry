---
name: aif-fix
description: Walk a human through a rejected foundry artifact — read the gate's complaints, explain why each one was raised, fix what is mechanically fixable, and send the rest back upstream where it belongs. Use when a gate has rejected spec.md, plan.md, tests or code, when a station is rejected during `aif run`, or when the user invokes /aif-fix. Not for writing a ticket from scratch — that is aif-ticket.
---

# aif-fix — the repair bench at a gate

A gate rejected an artifact. This skill is the human-facing half of that rejection: it turns
a list of machine complaints into a short conversation, fixes what is genuinely a wording or
form problem, and refuses to fix what is actually a scoping problem in disguise.

It is **not** a station and has no gate of its own. It edits an artifact that a station
produced, so that the artifact's own gate will pass against real content.

## The one rule that governs everything here

**Never make the gate pass by making the artifact worse.**

Every gate here is a *proxy*. `spec-form` counts criteria and matches verbs; it cannot see
meaning. So there is always a cheap way to satisfy it that destroys the thing it was
protecting — delete six acceptance criteria to get under a limit, replace a real assertion
with a trivially true one, water down a `then` until it says nothing. Each of those turns a
red gate green and leaves the project worse than the rejection did.

If the only way you can see to satisfy a gate is to remove or weaken content, that is the
gate telling you the problem is **upstream** — in the ticket, or in the scope. Say so, and
take it to the user. Do not do it quietly.

## Procedure

### 1. Establish what was rejected, from the gate itself

Do not work from the error text the user pasted; it may be stale. Re-derive it:

- The station's agent file `.claude/agents/aif-<STATION>.md` names the artifact (`produces`)
  and its gate(s) (`form_gate`, or `gates`) in its `aif:meta` block. It also carries
  `expects` — one line saying what the station was supposed to produce, which is the
  cheapest way to see how far the output fell short.
- Run each gate yourself: `bash .aif/gates/<GATE>.sh tasks/<ID>` — exit `0` pass,
  `1` the artifact is rejected, `3` the gate could not render a verdict.
- **Exit 3 is not yours to fix in the artifact.** It means the gate broke or the environment
  is wrong (an unparseable file, a missing tool, an already-broken repo). Report it and stop;
  editing the artifact cannot help.
- Read the gate script. It is the authority on *why* a rule exists, and the good ones say so
  in their header comments, including what they knowingly cannot catch. Explain the rule to
  the user in those terms, not as "the linter wants X".

### 2. Sort the complaints into two piles

This is the judgement the skill exists for. Before fixing anything, put every complaint into
one of these:

**Mechanical — the content is right, its form is wrong.** Fix these in the artifact:
- an assertion that joins two checks with "and"/"or" → split into two criteria
- a `then` with no assertion verb, or with two → rewrite to one verb from the gate's list
- a judgement word ("valid", "correct", "gracefully") → say what is observable instead
- `expect` holding prose instead of a literal → name the literal
- ids out of sequence, a `surface` missing from the surfaces list → correct the reference
- an assumption that is really a limit of verification → move it to `verification_gaps`
- a `surface_map` entry missing for a surface the spec names → add the file set

**Structural — the artifact is honest and the gate is telling you the work is too big or
the input was too vague.** These are the user's call, never yours:
- "N criteria, limit is M — split the ticket" → the ticket covers too much. The fix is to
  narrow this ticket and move the rest to another one. **Deleting criteria is not the fix.**
- a criterion nobody can state a literal for → the ticket never decided that behaviour;
  it needs an answer from the user, not a guess from you
- the judge found a blocker that is a genuine gap in intent → back to the ticket
- `external` names a dependency with no check and no criterion → **do not invent either
  one.** A check name the project does not have is a rejection; a criterion written to be
  pointed at rather than to be true is worse, because it passes. The honest fixes are: add
  a real check to `.aif/project.json` with the user, write a criterion that exercises the
  real dependency, or leave it as a gap and let the human see it at the gate.
- a criterion the judge adjudicated as surface `drift` → the plan pinned a criterion to less
  than the surface it was written about. Widening `ac_coverage` to silence the flag is only
  right if the criterion really is about the wider set; otherwise the planning is wrong.

For a structural finding, propose the split or the question concretely — name which criteria
would stay and which would move — and let the user decide. When they decide, the change goes
into `tasks/<ID>/ticket.md`, because the spec station reads the ticket and nothing else.

### 3. Fix the mechanical pile

**Prefer re-dispatching the station over editing the artifact yourself.** Hand it the gate's
objection verbatim and let it rewrite its own output: it has the full instructions and the
context that produced the artifact, where you have one line of complaint. That is the normal
path and it is usually cheaper than the argument about whether a hand edit was faithful.

Edit by hand when re-dispatching would be absurd for the size of the fix — a mistyped id, a
`surface` naming something the spec calls slightly differently — or when the station has
already been re-dispatched and produced the same defect.

When you do edit, show the user each fix as a before/after of the exact field. Keep the
meaning identical — you are re-expressing an assertion, not choosing a new one. Where
splitting one criterion into two changes the ids that follow, renumber contiguously from
`AC-001`, as the gate requires.

Where a fix would require *deciding* something the artifact did not say — a boundary, a
status code, an exact literal — stop and ask. An invented literal is an unreviewed decision
that will be tested as though a human chose it.

### 4. Re-run the gate, and keep going until it is green or stuck

After each round, re-run the gate. Report what is left. Stop when:
- the gate passes → say so, and hand back (step 5); or
- what remains is all structural → say exactly that, name what the user has to decide, and
  stop. Do not grind at a rule you cannot satisfy honestly.

If a gate keeps rejecting the same thing after two attempts at it, stop and say what you do
not understand rather than trying a third variation. A gate you cannot satisfy is
information, not an obstacle.

### 5. Hand back

State the artifact's state plainly, and name the next command without running it:

- gate green → say so and stop. If the `aif` orchestrator invoked you, simply return: it
  asks `aif _state <ID>` what comes next and re-checks with `aif _gate` itself. Do not
  dispatch the next station yourself — that decision comes from derived state, not from your
  memory of what you just fixed.
- gate still red for structural reasons → the change belongs in `ticket.md`. `aif _rework
  <ID> "<what should change>"` folds it in as prose, which is what the spec station actually
  reads, and the spec is redone against it.
- a person invoked you directly → `aif run <ID>` continues from here.

## What this skill cannot do — stated so it does not oversell

- It cannot tell whether the artifact describes the **right** thing to build. Every gate here
  checks form; `spec-judge` and the human approval gate are what stand between a
  well-formed spec and a correct one, and both are still downstream.
- It cannot rescue a bad ticket. Where the rejection traces to an unclear or oversized
  ticket, the honest outcome of this skill is a change to `ticket.md` and a re-run — not a
  patched artifact.
- A green gate here is not an approval. The human approval is still yours to give.
