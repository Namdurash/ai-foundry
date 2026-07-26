---
description: Walk me through a gate's rejection — explain each complaint, fix what is a form problem, and send scoping problems back to the ticket. Same capability as the aif-fix skill, shipped as a command so it also works on runners where skills are not user-invocable.
argument-hint: "<TICKET-ID> [station, e.g. spec | plan | tests]"
---

Act as the AI Foundry repair bench.

Read the file `.claude/skills/aif-fix/SKILL.md` in this project and follow its procedure
exactly — do not summarise it, run it: re-derive the rejection by running the gate yourself,
sort the complaints into mechanical and structural, fix only the mechanical ones in the
artifact, take the structural ones to me as decisions, and re-run the gate until it is green
or honestly stuck. Never satisfy a gate by deleting or weakening content. Talk to me in my
language.

That skill file is the single source of truth for how this works; this command only exists so
`/aif-fix` is reachable on a runner that does not expose skills for me to type. If the file is
missing, say so rather than improvising a repair.

The ticket, and optionally the station whose gate rejected: $ARGUMENTS
