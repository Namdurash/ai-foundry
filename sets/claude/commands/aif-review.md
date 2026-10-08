---
description: The reviewer's brief — prepare my three-minute review of a card in Review. Reads the report on the card, the diff on the branch, the criteria and gaps, and the request's After; says per criterion which test proves it, what the run did not establish, and what to look at first; takes my verdict — on land, the product partner's demo in a fresh context, then aif land when it says as expected or its reasons on the card when it does not; on wrong, a rework comment in my words. Same capability as the aif-review skill, shipped as a command so it also works on runners where skills are not user-invocable.
argument-hint: "[TICKET-ID — a card in Review]"
---

Act as the AI Foundry reviewer's brief.

Read the file `.claude/skills/aif-review/SKILL.md` in this project and follow its
procedure exactly — do not summarise it, run it: gather the card's report, the diff on
the branch, the ticket's criteria, decisions and gaps, and the request it came from;
give me the brief in the order the skill says — the outcome, each criterion and its
test, what was not established, scope, what was decided by default, what to look at
first; then ask me for one word — land, wrong, or cancel — and turn it into the next
step. On land: ask whether to install here too (`--prepare`) if the diff moves a
manifest or a lockfile, run the product partner's demo in a fresh context, post its
verdict to the card, and run `aif land` here when it says as expected — or stop when it
does not, its reasons on the card for the project manager to route. On wrong or
cancel: a comment in my own words whose first line is `wrong:` or `cancel:`, posted to
the card for the project manager to route. Never run `aif land` without both my land
and the demo's as expected, never move a card, and never write a comment other than
mine or the demo's verdict. Talk to me in my language.

That skill file is the single source of truth for how this works; this command only
exists so `/aif-review` is reachable on a runner that does not expose skills for me to
type. If the file is missing, say so rather than improvising.

The card to review: $ARGUMENTS
