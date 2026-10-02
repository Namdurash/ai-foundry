#!/usr/bin/env bash
#
# scripts/cycle.sh — the development cycle, drawn from the code that runs it.
#
# docs/CYCLE.md, and docs/CYCLE.html as the same picture on a page, are NOT
# written by hand. Every station, gate, column, role and cap in them is read
# from the file that defines it — the agents' aif:meta, the stage list in
# lib/run.sh, the columns in lib/board.sh, the skills' frontmatter, the
# limits in the project template — and the few facts that live in control
# flow or in prose (the ready gate at intake, where the card goes when a run
# stops, one ticket per slice) are asserted against their source before they
# are drawn. A picture that could disagree with the code is worse than none:
# it would be read as the design and trusted over the thing that runs.
#
#   scripts/cycle.sh            write docs/CYCLE.md and docs/CYCLE.html
#   scripts/cycle.sh --verify   fail if either differs from what would be written
#
# `make cycle` is the first; `make check` runs the second, so the drawing
# cannot go stale in silence. bash 3.2, offline, no model.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"

SET="$ROOT/sets/claude"
TEMPLATE="$SET/project.templates/jest.json"
MD_OUT="docs/CYCLE.md"
HTML_OUT="docs/CYCLE.html"
MERMAID_CDN="https://cdnjs.cloudflare.com/ajax/libs/mermaid/11.6.0/mermaid.min.js"

die() {
  printf 'cycle: %s\n' "$*" >&2
  exit 1
}

aif_have jq || die "jq is required"

# anchor <file> <literal> <claim> — a fact the drawing states that lives in
# control flow or prose rather than in a declaration. When the grep fails the
# code has moved, and the drawing must be re-read, not regenerated.
anchor() {
  grep -qF -- "$2" "$ROOT/$1" ||
    die "$1 no longer says '$2' — the drawing claims: $3. Re-read the code, then update scripts/cycle.sh"
}

# frontmatter_get <file> <key> — flat `key: value`, as scripts/check-set.sh reads it.
frontmatter_get() {
  awk -v key="$2" '
    NR == 1 && $0 == "---" { inblock = 1; next }
    inblock && $0 == "---" { exit }
    inblock && index($0, key ":") == 1 { sub(/^[^:]*:[ \t]*/, ""); print; exit }
  ' "$1"
}

html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# --------------------------------------------------------------------------
# 1. what the code declares
# --------------------------------------------------------------------------
stages="$(sed -n 's/^AIF_RUN_STAGES="\(.*\)"$/\1/p' "$ROOT/lib/run.sh" | head -1)"
[ -n "$stages" ] || die "lib/run.sh no longer declares AIF_RUN_STAGES"
columns="$(sed -n 's/^AIF_BOARD_COLUMNS="\(.*\)"$/\1/p' "$ROOT/lib/board.sh" | head -1)"
[ -n "$columns" ] || die "lib/board.sh no longer declares AIF_BOARD_COLUMNS"
for c in backlog ready in_progress review "done" needs_human; do
  case " $columns " in *" $c "*) ;; *) die "lib/board.sh has no '$c' column — the drawing routes cards through it" ;; esac
done

routine="$(jq -r '.tiers.routine // "?"' "$TEMPLATE")"
careful="$(jq -r '.tiers.careful // "?"' "$TEMPLATE")"
attempts_max="$(jq -r '.limits.attempts_max // "?"' "$TEMPLATE")"
dispatches_max="$(jq -r '.limits.run_dispatches_max // "?"' "$TEMPLATE")"
minutes_max="$(jq -r '.limits.run_max_minutes // "?"' "$TEMPLATE")"
budget="$(jq -r '.limits.run_budget_usd // "off unless a project or the caller sets it"' "$TEMPLATE")"

# --------------------------------------------------------------------------
# 2. what the code does — asserted, because it is not declared anywhere
# --------------------------------------------------------------------------
# One line each: file | the literal it must contain | what the drawing claims.
# A quoted heredoc, so the literals are read verbatim — several contain the
# source's own "$var" spellings, which are grep patterns here, not expansions.
while IFS='|' read -r a_file a_literal a_claim; do
  [ -n "$a_file" ] || continue
  anchor "$a_file" "$a_literal" "$a_claim"
done <<'ANCHORS'
lib/cmd_work.sh|aif_gate_run "$wt" ready|the ready gate runs at intake, before the first token
lib/cmd_work.sh|aif_board_move "$root" "$ticket" in_progress|the card moves to In progress before anything is spent
lib/cmd_work.sh|aif_board_move "$root" "$ticket" needs_human|a ticket refused at intake goes to Needs Human with the gate's lines
lib/cmd_work.sh|col=review|a built ticket's card goes to Review with the report
lib/cmd_work.sh|col=needs_human|a stopped run's card goes to Needs Human with what it tried
lib/cmd_work.sh|retrying with the complaint|a rejected station is retried with the gate's complaint
sets/claude/skills/aif-po/SKILL.md|requests/<slug>.md|the product partner writes requests/<slug>.md
sets/claude/skills/aif-po/SKILL.md|## Slices|a request is cut into slices that ship on their own
sets/claude/skills/aif-po/SKILL.md|## Status|a new request carries a Status line
sets/claude/skills/aif-po/SKILL.md|not cut|…and starts as not cut
sets/claude/skills/aif-ba/SKILL.md|One ticket never spans two slices|the analyst cuts one ticket per slice
sets/claude/skills/aif-ba/SKILL.md|--column ready|the first slice's ticket goes to Ready
sets/claude/skills/aif-ba/SKILL.md|the rest to **Backlog**|the other slices' tickets go to Backlog, in slice order
sets/claude/skills/aif-ba/SKILL.md|aif _ready <ID>|the analyst ends with the Definition of Ready
sets/claude/skills/aif-ba/SKILL.md|**Then mark the request.**|the analyst marks the request after the cards are made
sets/claude/skills/aif-ba/SKILL.md|`not cut`, `cut in part`, `cut`|the status is one of not cut, cut in part, cut
sets/claude/skills/aif-pjm/SKILL.md|rework:|the project manager routes a review comment as rework, to Backlog
sets/claude/skills/aif-pjm/SKILL.md|cancelled:|…or cancels the card to Done
sets/claude/skills/aif-pjm/SKILL.md|`aif work` takes the top card|the worker consumes the top of Ready
lib/cmd_work.sh|--loop|aif work --loop drains Ready
lib/cmd_land.sh|aif_board_move "$root" "$ticket" "done"|aif land moves the landed card to Done
lib/cmd_land.sh|_aif_land_release|aif land releases the tickets that were waiting on the landed one
lib/cmd_land.sh|reset --hard "$pre"|a red suite on the result undoes the merge
sets/claude/skills/aif-ba/SKILL.md|depends_on|a ticket names the tickets it needs built first
sets/claude/skills/aif-review/SKILL.md|aif land <ID>|the reviewer's brief ends in aif land, or a comment
ANCHORS

# --------------------------------------------------------------------------
# 3. the stations, from their own files, in the order lib/run.sh runs them
# --------------------------------------------------------------------------
station_rows=""    # stage|engine|gates|attempts|requires|leaves
mermaid_stations=""
prev_gate="G_READY"
first_retry=1
attempts_exceptions=""
for stage in $stages; do
  f="$SET/agents/aif-$stage.md"
  [ -f "$f" ] || die "lib/run.sh runs '$stage' but sets/claude/agents/aif-$stage.md does not exist"
  meta="$(aif_meta_json "$f")"
  [ "$(printf '%s' "$meta" | jq -r '.station // ""')" = "$stage" ] ||
    die "aif-$stage.md declares station '$(printf '%s' "$meta" | jq -r '.station // ""')', not '$stage'"

  tier="$(printf '%s' "$meta" | jq -r '.tier // ""')"
  case "$tier" in
    careful) engine="$careful (careful)"; short="$careful" ;;
    routine) engine="$routine (routine)"; short="$routine" ;;
    risk)
      [ -f "$SET/agents/$(printf '%s' "$meta" | jq -r '.agents.careful // "-"').md" ] ||
        die "aif-$stage.md is tiered by risk but names no careful variant that exists"
      engine="$routine, or $careful when the ticket's risk is high"
      short="$routine · $careful if risk is high"
      ;;
    *) die "aif-$stage.md declares no tier" ;;
  esac

  gates="$(printf '%s' "$meta" | jq -r '[.form_gate // empty] + (.gates // []) | join(", ")')"
  [ -n "$gates" ] || die "aif-$stage.md names no gate — every station is judged by one"
  for g in $(printf '%s' "$gates" | tr -d ','); do
    [ -f "$SET/gates/$g.sh" ] || die "aif-$stage.md is checked by '$g', but sets/claude/gates/$g.sh does not exist"
  done
  requires="$(printf '%s' "$meta" | jq -r '(.requires // []) | join(", ")')"
  leaves="$(printf '%s' "$meta" | jq -r '
    [ (.produces // empty),
      ((.freezes // empty) | . + ", frozen"),
      ((.binds // empty) | "the code, bound to " + .) ] | join("; ")')"
  # How many rejections in a row the station gets: its own max_attempts, else
  # the project-wide limits.attempts_max (lib/cmd_work.sh,
  # _aif_work_attempts_max). The tests station declares four.
  station_attempts="$(printf '%s' "$meta" | jq -r '.max_attempts // empty')"
  [ -n "$station_attempts" ] || station_attempts="$attempts_max"
  station_rows="$station_rows$stage|$engine|$gates|$station_attempts|$requires|$leaves
"
  [ "$station_attempts" = "$attempts_max" ] || attempts_exceptions="$attempts_exceptions, $stage $station_attempts"

  gate_word="gate"
  case "$gates" in *,*) gate_word="gates" ;; esac
  retry='-.->'
  if [ "$first_retry" -eq 1 ]; then
    retry="-.->|\"rejected: retried with the complaint, up to $attempts_max times\"|"
    first_retry=0
  elif [ "$station_attempts" != "$attempts_max" ]; then
    retry="-.->|\"rejected: up to $station_attempts times\"|"
  fi
  mermaid_stations="$mermaid_stations    S_${stage}[\"station $stage · $short\"] --> G_${stage}{{\"$gate_word $gates\"}}
    $prev_gate --> S_${stage}
    G_${stage} $retry S_${stage}
"
  prev_gate="G_$stage"
done
last_gate="$prev_gate"

# --------------------------------------------------------------------------
# 4. the roles, from the skills' frontmatter
# --------------------------------------------------------------------------
role_rows="" # skill|role|requires
# In the order the cycle runs them, then whatever else the set ships.
skills=""
for n in po ba review pjm; do
  [ -f "$SET/skills/aif-$n/SKILL.md" ] && skills="$skills $SET/skills/aif-$n/SKILL.md"
done
for f in "$SET"/skills/aif-*/SKILL.md; do
  case " $skills " in *" $f "*) ;; *) skills="$skills $f" ;; esac
done
for f in $skills; do
  name="$(frontmatter_get "$f" name)"
  desc="$(frontmatter_get "$f" description)"
  role="${desc%% — *}"
  [ "$role" != "$desc" ] || role="${desc%%. *}"
  req="$(frontmatter_get "$f" requires | tr -d '[]' | tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')"
  [ -n "$req" ] || req="nothing"
  role_rows="$role_rows/$name|$role|$req
"
done

repairs_max="$(jq -r '.limits.repairs_max // "?"' "$TEMPLATE")"
replans_max="$(jq -r '.limits.replans_max // "?"' "$TEMPLATE")"
grep -q '_aif_work_attempts_max' "$ROOT/lib/cmd_work.sh" || die "lib/cmd_work.sh no longer reads a station's own max_attempts — the attempts column below is drawn from it"
cap_rows="a station rejected in a row|$attempts_max${attempts_exceptions:+ (}${attempts_exceptions#, }${attempts_exceptions:+)}|limits.attempts_max, or max_attempts in the station's aif:meta
the same complaint twice in a row|stop|the convergence rule, lib/cmd_work.sh
repairs of the oracle, per ticket|$repairs_max|limits.repairs_max
replans, per ticket|$replans_max|limits.replans_max
station runs in one ticket's run|$dispatches_max|limits.run_dispatches_max
wall clock, minutes|$minutes_max|limits.run_max_minutes
dollars|$budget|limits.run_budget_usd
"
# The two loops that are not retries, asserted where they live rather than
# typed in: green's REPAIR verdict sends the tests station round again, and
# the implementer's note sends the plan station round again.
grep -q 'AIF_G_REPAIR' "$SET/gates/green.sh" || die "green.sh no longer answers REPAIR (exit 4) — the repair loop is drawn below"
grep -q '_aif_work_repair' "$ROOT/lib/cmd_work.sh" || die "lib/cmd_work.sh no longer repairs the oracle"
grep -q '_aif_work_replan' "$ROOT/lib/cmd_work.sh" || die "lib/cmd_work.sh no longer replans"
grep -q 'aif_g_spec' "$SET/gates/plan.sh" || die "plan.sh no longer answers a spec stop (exit 2)"

# --------------------------------------------------------------------------
# 5. the drawing
# --------------------------------------------------------------------------
diagram="$(cat <<MERMAID
flowchart TB
  subgraph HUMAN["Human time · no gates"]
    PO["/aif-po — the product partner<br/>challenges the need, cuts it into slices<br/>that ship on their own"]
    REQ(["requests/&lt;slug&gt;.md — the request<br/>Status: not cut → cut in part → cut"])
    BA["/aif-ba — the analyst<br/>one ticket per slice, never one across two<br/>tasks/&lt;ID&gt;/ticket.md with GIVEN / WHEN / THEN"]
    DOR{{"aif _ready — the Definition of Ready<br/>every open question answered, or its default taken"}}
    PJM["/aif-pjm — the project manager<br/>orders Ready, routes the reviewer's words"]
    QA["/aif-review — the reviewer's brief<br/>per criterion its test, what was not established,<br/>the request's After — then the verdict"]
    PO -->|"writes it — Status: not cut"| REQ
    REQ -->|"the slices"| BA
    BA -.->|"marks it after the cards: cut in part, then cut"| REQ
    BA --> DOR
    DOR -.->|"open questions, each with a default"| BA
  end

  subgraph BOARD["The board · aif board"]
    BACKLOG[Backlog]
    READY[Ready]
    IN_PROGRESS[In progress]
    REVIEW[Review]
    DONE[Done]
    NEEDS_HUMAN[Needs Human]
    BACKLOG -->|"released by aif land, or by /aif-pjm by hand"| READY
  end

  subgraph MACHINE["Machine time · aif work"]
    INTAKE["intake — the ticket's bytes frozen<br/>one worktree, one branch aif/&lt;ID&gt;, one budget"]
    G_READY{{"gate ready"}}
    INTAKE --> G_READY
$mermaid_stations    REPORT["report.md, beside the diff on the branch"]
    $last_gate --> REPORT
    G_implement -.->|"the oracle's, not the code's: repaired by the tests station<br/>in a copy without the implementation, ≤ $repairs_max per ticket"| S_tests
    G_implement -.->|"the contract cannot hold it, says the implementer: replanned, ≤ $replans_max per ticket"| S_plan
    LAND["aif land — merge into the checkout's branch,<br/>the suite on the result, Done, the next slice released"]
  end

  DOR -->|"the first slice"| READY
  DOR -->|"the other slices, in order"| BACKLOG
  READY -->|"the top card — one, or --loop until empty"| INTAKE
  INTAKE -.->|"the card"| IN_PROGRESS
  G_READY -->|"not ready: the gate's questions, nothing spent"| NEEDS_HUMAN
  G_plan -->|"a criterion already true, unfalsifiable, in conflict, undecided:<br/>a spec stop, one dispatch, nothing frozen"| NEEDS_HUMAN
  REPORT -->|"built"| REVIEW
  REPORT -->|"stopped: a cap hit, or a station that will not converge"| NEEDS_HUMAN
  REVIEW -->|"the card, the diff, the report"| QA
  QA -->|"land it"| LAND
  QA -->|"wrong — a comment in the reviewer's words"| PJM
  LAND -->|"merged, the suite green"| DONE
  LAND -->|"a conflict, or red on the result: the merge undone"| NEEDS_HUMAN
  LAND -.->|"the next slice, when all it depends on is Done"| READY
  NEEDS_HUMAN --> PJM
  PJM -->|"rework, in the reviewer's words"| BACKLOG
  PJM -->|"cancelled"| DONE
  BACKLOG -.->|"/aif-ba reworks the criteria"| BA
MERMAID
)"

# table_md <header|...> <rows> — a GitHub table from pipe-separated rows.
table_md() {
  printf '%s\n' "$1" | awk -F'|' '{ printf "|"; for (i = 1; i <= NF; i++) printf " %s |", $i; printf "\n|"; for (i = 1; i <= NF; i++) printf "---|"; printf "\n" }'
  printf '%s' "$2" | awk -F'|' 'NF { printf "|"; for (i = 1; i <= NF; i++) printf " %s |", $i; printf "\n" }'
}

# table_html <header|...> <rows> — the same table, cells escaped.
table_html() {
  printf '<table>\n<thead><tr>'
  printf '%s\n' "$1" | html_escape | awk -F'|' '{ for (i = 1; i <= NF; i++) printf "<th>%s</th>", $i }'
  printf '</tr></thead>\n<tbody>\n'
  printf '%s' "$2" | html_escape | awk -F'|' 'NF { printf "<tr>"; for (i = 1; i <= NF; i++) printf "<td>%s</td>", $i; printf "</tr>\n" }'
  printf '</tbody>\n</table>\n'
}

columns_pretty="$(printf '%s' "$columns" | sed 's/ needs_human$//' | tr ' ' '\n' | sed 's/_/ /' | tr '\n' '|' | sed 's/|$//; s/|/ → /g')"

emit_md() {
  cat <<EOM
# The cycle, as the code has it

<!-- Generated by scripts/cycle.sh from the set and the CLI. Do not edit by hand:
     \`make cycle\` regenerates it, and \`make check\` fails while it is stale. -->

Two halves, one boundary. The human half is a conversation with no gates: it
decides what is worth building and writes it down. The machine half is headless
and never asks: it builds what the ticket says, and a gate judges every station.
They meet only on the board.

\`\`\`mermaid
$diagram
\`\`\`

## The human half — the roles

Each is a skill under \`sets/claude/skills/\`, and a slash command of the same
name. \`/aif-setup\` says which of them can run on this machine.

What passes between the first two is a file, \`requests/<slug>.md\`, and it carries
its own status: \`not cut\` when the product partner writes it, \`cut in part\` with one
line per slice once the analyst has made cards, \`cut\` when every slice has one.

$(table_md "skill|role|needs" "$role_rows")

## The board

The columns \`lib/board.sh\` knows, on a local board or on Trello — and \`aif land\`
is how a card leaves Review for Done:

\`$columns_pretty\`, plus \`Needs Human\`.

Every transition goes through \`aif board\`.

## The machine half — stations and gates

The stage order is the list in \`lib/run.sh\`; each station's own file says
which gate judges it. The \`ready\` gate runs first, at intake, before the first
token, and it is the same script the analyst ran at the end of the conversation.

$(table_md "stage|engine|judged by|attempts|requires|leaves behind" "$station_rows")

## The caps on one run

From \`sets/claude/project.templates/\`; a project's own \`.aif/project.json\`
may set others. The wall clock and the dispatch cap always apply.

$(table_md "cap|value|setting" "$cap_rows")
EOM
}

emit_html() {
  cat <<'EOH'
<title>AI Foundry Cycle</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans+Condensed:wght@500;600&family=IBM+Plex+Sans:wght@400;500&family=IBM+Plex+Mono&display=swap">
<style>
  :root {
    --bg: #eef0f2; --surface: #ffffff; --surface-2: #f5f7f9;
    --ink: #171c21; --muted: #5f6b76; --line: #d6dce2; --line-strong: #8d98a3;
    --human: #b45309; --machine: #1d4ed8; --board: #475569;
    --font-body: "IBM Plex Sans", system-ui, -apple-system, "Segoe UI", sans-serif;
    --font-display: "IBM Plex Sans Condensed", "IBM Plex Sans", system-ui, sans-serif;
    --font-mono: "IBM Plex Mono", ui-monospace, SFMono-Regular, Menlo, monospace;
  }
  @media (prefers-color-scheme: dark) {
    :root:not([data-theme="light"]) {
      --bg: #0f1418; --surface: #161c22; --surface-2: #1c242c;
      --ink: #e7ebee; --muted: #98a4af; --line: #2a343e; --line-strong: #5b6873;
      --human: #f59e0b; --machine: #60a5fa; --board: #94a3b8;
      color-scheme: dark;
    }
  }
  :root[data-theme="dark"] {
    --bg: #0f1418; --surface: #161c22; --surface-2: #1c242c;
    --ink: #e7ebee; --muted: #98a4af; --line: #2a343e; --line-strong: #5b6873;
    --human: #f59e0b; --machine: #60a5fa; --board: #94a3b8;
    color-scheme: dark;
  }
  body { background: var(--bg); color: var(--ink); font-family: var(--font-body); font-size: 15px; line-height: 1.5; }
  .page { max-width: 1240px; margin: 0 auto; padding-block: 28px 40px; padding-inline: 20px; display: grid; gap: 28px; }
  header { display: grid; gap: 8px; max-width: 68ch; }
  .eyebrow { margin: 0; font-family: var(--font-mono); font-size: 12px; letter-spacing: 0.06em; text-transform: uppercase; color: var(--muted); }
  h1 { margin: 0; font-family: var(--font-display); font-weight: 600; font-size: clamp(28px, 4vw, 40px); line-height: 1.1; letter-spacing: -0.01em; text-wrap: balance; }
  .lede { margin: 0; color: var(--muted); }
  .lede b { color: var(--ink); font-weight: 500; }
  .diagram-wrap { background: var(--surface); border: 1px solid var(--line); border-radius: 8px; overflow-x: auto; padding: 16px; }
  .diagram svg { display: block; width: 100%; height: auto; min-width: 640px; margin: 0 auto; }
  .diagram .src { margin: 0; font-family: var(--font-mono); font-size: 12px; color: var(--muted); white-space: pre; }
  .diagram .cluster rect { stroke-width: 1.5px; }
  .legend { display: flex; flex-wrap: wrap; gap: 8px 20px; margin: 0; padding: 0; list-style: none; font-size: 13px; color: var(--muted); }
  .legend li::before { content: ""; display: inline-block; width: 10px; height: 10px; border-radius: 2px; margin-right: 8px; vertical-align: -1px; background: var(--dot); }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 20px; align-items: start; }
  section.block { display: grid; gap: 10px; min-width: 0; }
  section.block h2 { margin: 0; font-family: var(--font-display); font-weight: 600; font-size: 20px; }
  section.block h2 small { display: block; font-family: var(--font-mono); font-size: 11px; font-weight: 400; letter-spacing: 0.06em; text-transform: uppercase; margin-bottom: 4px; }
  section.block p { margin: 0; color: var(--muted); font-size: 14px; }
  .human h2 small { color: var(--human); } .machine h2 small { color: var(--machine); } .board h2 small { color: var(--board); }
  .table-wrap { overflow-x: auto; }
  table { border-collapse: collapse; width: 100%; font-size: 13.5px; }
  th, td { text-align: left; vertical-align: top; padding: 7px 10px; border-bottom: 1px solid var(--line); }
  th { font-family: var(--font-mono); font-weight: 400; font-size: 11px; letter-spacing: 0.06em; text-transform: uppercase; color: var(--muted); }
  td:first-child { font-family: var(--font-mono); font-size: 12.5px; white-space: nowrap; }
  tbody tr:last-child td { border-bottom: 0; }
  code { font-family: var(--font-mono); font-size: 0.92em; background: var(--surface-2); padding: 1px 5px; border-radius: 3px; }
  footer { border-top: 1px solid var(--line); padding-top: 16px; color: var(--muted); font-size: 13.5px; max-width: 78ch; display: grid; gap: 6px; }
  footer p { margin: 0; }
  a { color: var(--machine); }
  :focus-visible { outline: 2px solid var(--machine); outline-offset: 2px; }
  @media (prefers-reduced-motion: no-preference) { .diagram svg { transition: opacity 0.2s ease; } }
</style>
<main class="page">
  <header>
    <p class="eyebrow">Drawn from the code · scripts/cycle.sh</p>
    <h1>AI Foundry Cycle</h1>
    <p class="lede"><b>Two halves, one boundary.</b> The human half is a conversation with no gates: it decides what is worth building and writes it down. The machine half is headless and never asks: it builds what the ticket says, and a gate judges every station. They meet only on the board.</p>
  </header>

  <section class="diagram-wrap" aria-label="The cycle">
    <div id="cycle" class="diagram"><pre id="cycle-src" class="src">
EOH
  printf '%s' "$diagram" | html_escape
  cat <<'EOH'
</pre></div>
  </section>
  <ul class="legend" aria-label="Reading the diagram">
    <li style="--dot: var(--human)">Human time — a skill, run when you want, for as long as you want</li>
    <li style="--dot: var(--board)">The board — where the state is seen; every move goes through <code>aif board</code></li>
    <li style="--dot: var(--machine)">Machine time — <code>aif work</code>, one ticket, one worktree, no questions; <code>aif land</code> is the yes after review</li>
    <li style="--dot: var(--line-strong)">Hexagons are gates: a verdict, retried with the complaint, never a conversation</li>
    <li style="--dot: var(--human)">The rounded node is the request itself, a file with a status line the analyst keeps true</li>
  </ul>

  <div class="grid">
    <section class="block human">
      <h2><small>The human half</small>Roles</h2>
      <p>Each is a skill under <code>sets/claude/skills/</code> and a slash command of the same name. <code>/aif-setup</code> says which can run on this machine.</p>
      <p>What passes between the first two is a file, <code>requests/&lt;slug&gt;.md</code>, with a status of its own: <code>not cut</code> when the product partner writes it, <code>cut in part</code> with one line per slice once the analyst has made cards, <code>cut</code> when every slice has one.</p>
      <div class="table-wrap">
EOH
  table_html "skill|role|needs" "$role_rows"
  cat <<EOH
      </div>
    </section>
    <section class="block board">
      <h2><small>The boundary</small>The board</h2>
      <p><code>$(printf '%s' "$columns_pretty" | html_escape)</code>, plus <code>Needs Human</code>: the columns <code>lib/board.sh</code> knows, on a local board or on Trello. The first slice's ticket lands in Ready; the other slices wait in Backlog, and <code>aif land</code> releases each one when the tickets it depends on are Done.</p>
    </section>
    <section class="block machine">
      <h2><small>The machine half</small>Stations and gates</h2>
      <p>The stage order is the list in <code>lib/run.sh</code>; each station's own file names the gate that judges it. The <code>ready</code> gate runs first, at intake, before the first token: the same script the analyst ran at the end of the conversation.</p>
      <div class="table-wrap">
EOH
  table_html "stage|engine|judged by|attempts|requires|leaves behind" "$station_rows"
  cat <<'EOH'
      </div>
    </section>
    <section class="block machine">
      <h2><small>The machine half</small>Caps on one run</h2>
      <p>From <code>sets/claude/project.templates/</code>; a project's own <code>.aif/project.json</code> may set others. The wall clock and the dispatch cap always apply.</p>
      <div class="table-wrap">
EOH
  table_html "cap|value|setting" "$cap_rows"
  cat <<EOH
      </div>
    </section>
  </div>

  <footer>
    <p><b>How this stays true.</b> Nothing here was typed in: <code>scripts/cycle.sh</code> reads the stations, gates, columns, roles and caps from the files that define them, asserts the facts that live in control flow, and writes <code>docs/CYCLE.md</code> and this page. <code>make check</code> fails while either is stale.</p>
    <p>This page is a published copy of <code>docs/CYCLE.html</code>. After <code>make cycle</code>, republish it.</p>
  </footer>
</main>
<script src="$MERMAID_CDN"></script>
<script>
(function () {
  var host = document.getElementById('cycle');
  var srcEl = document.getElementById('cycle-src');
  if (!host || !srcEl) return;
  var src = srcEl.textContent;
  var seq = 0;
  function token(name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); }
  function draw() {
    if (!window.mermaid) return;
    mermaid.initialize({
      startOnLoad: false,
      theme: 'base',
      flowchart: { curve: 'basis', htmlLabels: true, padding: 14, nodeSpacing: 34, rankSpacing: 44 },
      themeVariables: {
        fontFamily: token('--font-body'), fontSize: '13px',
        primaryColor: token('--surface'), primaryTextColor: token('--ink'), primaryBorderColor: token('--line-strong'),
        secondaryColor: token('--surface-2'), tertiaryColor: token('--surface-2'),
        lineColor: token('--line-strong'), textColor: token('--ink'),
        clusterBkg: token('--surface-2'), clusterBorder: token('--line'),
        edgeLabelBackground: token('--surface'), titleColor: token('--ink')
      }
    });
    seq += 1;
    mermaid.render('cycle-svg-' + seq, src).then(function (r) {
      host.innerHTML = r.svg;
    }).catch(function (e) {
      host.textContent = 'The diagram did not render: ' + (e && e.message ? e.message : e);
    });
  }
  draw();
  try { window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', draw); } catch (e) {}
  try { new MutationObserver(draw).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] }); } catch (e) {}
})();
</script>
EOH
}

# --------------------------------------------------------------------------
# 6. write, or verify
# --------------------------------------------------------------------------
verify_one() { # <relative path> <generator fn>
  local tmp rc=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/aif-cycle-XXXXXX")"
  "$2" >"$tmp"
  if [ ! -f "$ROOT/$1" ]; then
    printf 'cycle: %s is missing — make cycle\n' "$1" >&2
    rc=1
  elif ! cmp -s "$tmp" "$ROOT/$1"; then
    printf 'cycle: %s is stale — the code moved and the drawing did not. make cycle, then commit it:\n' "$1" >&2
    diff "$ROOT/$1" "$tmp" | sed -n '1,12p' | sed 's/^/    /' >&2
    rc=1
  fi
  rm -f "$tmp"
  return "$rc"
}

case "${1:-}" in
  --verify)
    fails=0
    verify_one "$MD_OUT" emit_md || fails=1
    verify_one "$HTML_OUT" emit_html || fails=1
    [ "$fails" -eq 0 ] || exit 1
    printf 'cycle: %s and %s match the code\n' "$MD_OUT" "$HTML_OUT"
    ;;
  "")
    mkdir -p "$ROOT/docs"
    emit_md >"$ROOT/$MD_OUT"
    emit_html >"$ROOT/$HTML_OUT"
    printf 'cycle: wrote %s and %s\n' "$MD_OUT" "$HTML_OUT"
    printf '       the artifact on claude.ai is a copy of %s — republish it\n' "$HTML_OUT"
    ;;
  *)
    die "usage: scripts/cycle.sh [--verify]"
    ;;
esac
