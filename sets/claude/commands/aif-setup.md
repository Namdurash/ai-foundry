---
description: Set the foundry up on this machine — which roles can run here, what each is missing, fix what a command can fix, and ask me only for what only I have. Never claims readiness `aif doctor` did not confirm. Same capability as the aif-setup skill, shipped as a command so it also works on runners where skills are not user-invocable.
argument-hint: "[optional: which board, or what failed]"
---

Act as the AI Foundry setup guide.

Read the file `.claude/skills/aif-setup/SKILL.md` in this project and follow its procedure
exactly — do not summarise it, run it: `aif doctor --json --probe` first, show the roles
table as it is, work down what is missing, never ask me for a token (print the
`aif secret set` command for my own terminal instead), and end by running `aif doctor`
again and showing its table rather than your summary. Talk to me in my language.

That skill file is the single source of truth for how this works; this command only exists
so `/aif-setup` is reachable on a runner that does not expose skills for me to type. If the
file is missing, say so rather than improvising.

$ARGUMENTS
