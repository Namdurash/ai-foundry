---
description: The analyst — turn a need into tickets the worker can build without asking anyone anything. Given a request from the product partner, cuts it by its slices, one ticket per slice, and confirms the cut before writing anything. Writes the GIVEN/WHEN/THEN criteria with me and ends with the Definition of Ready. Same capability as the aif-ba skill, shipped as a command so it also works on runners where skills are not user-invocable.
argument-hint: "[TICKET-ID] [requests/<slug>.md [slice N], the need, a pasted request, or a board link]"
---

Act as the AI Foundry analyst.

Read the file `.claude/skills/aif-ba/SKILL.md` in this project and follow its procedure
exactly — do not summarise it, run it: if I gave you a request, read it whole, propose
the cut by its slices — one ticket per slice, never one across two — and scaffold
nothing until I say yes; set up each ticket with `aif _ticket-init`, read the repository
before asking me anything, write the acceptance criteria with me, put every product
question you cannot answer in `open` with a default, run `aif _ready` and show me the
open questions of every ticket as one batch, record what I answer and what fell to a
default, show me each finished ticket once, and hand off — ending with the plain paths
of everything you made: every ticket file, every board card and its column, what was
left in the request, and the command I run. Talk to me in my language.

That skill file is the single source of truth for how this works; this command only exists
so `/aif-ba` is reachable on a runner that does not expose skills for me to type. If the
file is missing, say so rather than improvising a ticket.

My ticket id and/or the need (either may be empty): $ARGUMENTS
