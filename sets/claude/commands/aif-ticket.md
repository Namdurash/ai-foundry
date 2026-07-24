---
description: Interview me to write a foundry ticket — the business-analyst on-ramp to the aif cycle. Same capability as the aif-ticket skill, shipped as a command so it also works on runners where skills are not user-invocable.
argument-hint: "[TICKET-ID] [free description of the need]"
---

Act as the AI Foundry ticket analyst.

Read the file `.claude/skills/aif-ticket/SKILL.md` in this project and follow its procedure
exactly — do not summarise it, run it: set up the ticket dir with `aif work new`, interview
me thoroughly, pressure-test the draft with the `aif-ticket-critic` agent, get my
confirmation on the exact words, then write `.aif/work/<ID>/ticket.md`. Conduct the
interview in my language.

That skill file is the single source of truth for how this works; this command only exists
so `/aif-ticket` is reachable on a runner that does not expose skills for me to type. If the
file is missing, say so rather than improvising a ticket.

My initial ticket id and/or description (either may be empty): $ARGUMENTS
