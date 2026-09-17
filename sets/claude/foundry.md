# AI Foundry

This project is set up with [AI Foundry](https://github.com/Namdurash/ai-foundry).
This file is generated — `aif init` overwrites it. Put your own project notes in
`CLAUDE.md` around the import, not here.

Foundry capabilities live in skills under `.claude/skills/aif-*`, which load only
when invoked. Nothing else here is always-on, deliberately: every line in this
file costs context on every single turn, in every session, forever. Content that
earns its place goes in a skill.

Two halves, one boundary: `/aif-ba` writes a ticket's GIVEN/WHEN/THEN criteria
*with* the human and ends with `aif _ready`; `aif work <ID>` builds it headless on
its own branch and never asks anyone anything. A ticket that is not ready comes
back with the gate's questions, not a guess.
