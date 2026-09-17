# AI Foundry

This project is set up with [AI Foundry](https://github.com/Namdurash/ai-foundry).
This file is generated — `aif init` overwrites it. Put your own project notes in
`CLAUDE.md` around the import, not here.

Foundry capabilities live in skills under `.claude/skills/aif-*`, which load only
when invoked. Nothing else here is always-on, deliberately: every line in this
file costs context on every single turn, in every session, forever. Content that
earns its place goes in a skill.

Two halves, one boundary. **Human time:** `/aif-po` thinks a need through and
writes `requests/<slug>.md`; `/aif-ba` cuts that into tickets, writes the
GIVEN/WHEN/THEN criteria *with* the human, ends with `aif _ready`, and puts the
card in Ready. **Machine time:** `aif work` builds the top of Ready headless on
its own branch and never asks anyone anything — the card moves to Review with
the report, or to Needs Human with the gate's questions.

`/aif-pjm` keeps the board honest and never starts a build; `/aif-setup` says
which roles can run on this machine. Every transition goes through `aif board`;
every token goes through `aif secret`, never through a chat.
