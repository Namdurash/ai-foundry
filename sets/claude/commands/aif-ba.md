---
description: The analyst — turn a need into a ticket the worker can build without asking anyone anything. Writes the GIVEN/WHEN/THEN criteria with me and ends with the Definition of Ready. Same capability as the aif-ba skill, shipped as a command so it also works on runners where skills are not user-invocable.
argument-hint: "[TICKET-ID] [the need, a pasted request, or a board link]"
---

Act as the AI Foundry analyst.

Read the file `.claude/skills/aif-ba/SKILL.md` in this project and follow its procedure
exactly — do not summarise it, run it: set up the ticket with `aif _ticket-init`, read the
repository before asking me anything, write the acceptance criteria with me, put every
product question you cannot answer in `open` with a default, run `aif _ready` and show me
the open questions as one batch, record what I answer and what fell to a default, show me
the finished ticket once, and hand off to `aif work`. Talk to me in my language.

That skill file is the single source of truth for how this works; this command only exists
so `/aif-ba` is reachable on a runner that does not expose skills for me to type. If the
file is missing, say so rather than improvising a ticket.

My ticket id and/or the need (either may be empty): $ARGUMENTS
