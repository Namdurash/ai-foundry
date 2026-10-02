#!/usr/bin/env bash
#
# scripts/check-set.sh — assertions about the claude set that no linter can make.
#
# A station is declared in ONE file read by TWO consumers: the runner reads the
# YAML frontmatter (name, tools, model), aif reads the aif:meta block (tier,
# produces, gates, preconditions). Nothing forces those two to agree, and when
# they disagree the symptom is a station quietly running on the wrong engine —
# which is what a whole ticket's cost overrun turned out to be. So it is checked.
#
# Run by `make check`. No model calls, no network.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
AGENTS="$ROOT/sets/claude/agents"

# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"

fails=0
ok()   { printf '  ✓ %s\n' "$1"; }
bad()  { printf '  ✗ %s\n' "$1"; fails=$((fails + 1)); }

# What each tier resolves to. The templates are the source of truth; reading
# them here rather than restating the mapping is the point — a template edited
# without the agents catches here instead of in a bill.
tier_model() {
  jq -r --arg t "$1" '.tiers[$t] // "?"' "$ROOT/sets/claude/project.templates/jest.json"
}

# frontmatter_get <file> <key> — a scalar from the YAML frontmatter.
# Deliberately not a YAML parser: the frontmatter aif writes is flat key: value,
# and a real parser is a dependency this set cannot assume in CI.
frontmatter_get() {
  awk -v key="$2" '
    NR == 1 && $0 == "---" { inblock = 1; next }
    inblock && $0 == "---" { exit }
    inblock && index($0, key ":") == 1 { sub(/^[^:]*:[ \t]*/, ""); print; exit }
  ' "$1"
}

# body_after_frontmatter <file> — everything the runner would treat as the
# agent's prompt, meta block included.
body_after_frontmatter() { sed '1,/^---$/d' "$1"; }

printf '\nstation declarations\n'

for f in "$AGENTS"/aif-*.md; do
  base="$(basename "$f")"
  meta="$(aif_meta_json "$f")"
  [ -n "$meta" ] || continue # not a station — no aif:meta block

  if ! printf '%s' "$meta" | jq -e . >/dev/null 2>&1; then
    bad "$base: aif:meta is not valid JSON"
    continue
  fi

  name="$(frontmatter_get "$f" name)"
  [ "$name" = "${base%.md}" ] ||
    bad "$base: frontmatter name is '$name' — it must match the filename, or the runner cannot find it"

  # Every station says, in one static line, what it is about to produce. The
  # orchestrator shows this before dispatching, so a step is legible before it
  # costs anything rather than after.
  printf '%s' "$meta" | jq -e '.expects' >/dev/null 2>&1 ||
    bad "$base: aif:meta has no 'expects' — nothing to tell the user before it runs"

  # A station's own caps, where it declares them: max_turns (the dispatch) and
  # max_attempts (rejections in a row, over limits.attempts_max — the tests
  # station gets four, docs/REBUILD-4.md §2.4). A string here would be read as
  # 0 and stop the station before its first retry.
  for cap in max_turns max_attempts; do
    printf '%s' "$meta" | jq -e --arg c "$cap" '(.[$c] // 1) | type == "number" and . >= 1' >/dev/null 2>&1 ||
      bad "$base: aif:meta $cap must be a number of 1 or more"
  done

  tier="$(printf '%s' "$meta" | jq -r '.tier // empty')"
  model="$(frontmatter_get "$f" model)"

  case "$tier" in
    risk)
      # Tiered per ticket, so one file cannot carry the answer: the two variants
      # do, and `aif work` picks by the ticket's risk.
      case "$base" in
        *-careful.md) want="$(tier_model careful)" ;;
        *) want="$(tier_model routine)" ;;
      esac
      ;;
    "") bad "$base: aif:meta declares no tier"; continue ;;
    *) want="$(tier_model "$tier")" ;;
  esac

  if [ "$model" = "$want" ]; then
    ok "$base: tier $tier → model $model"
  else
    bad "$base: aif:meta tier '$tier' maps to '$want', frontmatter says model '$model'"
  fi
done

printf '\ntier variants of one station carry identical instructions\n'
if diff <(body_after_frontmatter "$AGENTS/aif-implement.md") \
        <(body_after_frontmatter "$AGENTS/aif-implement-careful.md") >/dev/null 2>&1; then
  ok "aif-implement and aif-implement-careful differ only in frontmatter"
else
  bad "aif-implement and aif-implement-careful have drifted — the engine may differ, the instructions may not"
fi

printf '\na station is told to do only what its tools can\n'
# The runner gets the frontmatter's tools and nothing else (_aif_work_dispatch);
# the aif:meta copy is read by no code, so it can only mislead a reader who
# trusts it. And the station never sees either: its prompt is the body after
# the meta block. So nothing but this check stands between a station without
# Bash and a prompt telling it to run the suite — the tests station was told
# twice to run the tests and read the output, holding Read, Grep, Glob, Write
# and Edit. An order a station cannot carry out invites a claim that it did.
# The match is "Run" or "Execute" opening a line, a list item or a sentence:
# the spellings that happened, not a parse of English.
for f in "$AGENTS"/aif-*.md; do
  base="$(basename "$f")"
  meta="$(aif_meta_json "$f")"
  [ -n "$meta" ] || continue
  tools="$(frontmatter_get "$f" tools | tr -d ' ')"
  declared="$(printf '%s' "$meta" | jq -r '.tools // ""' | tr -s ' ' ',')"
  if [ -n "$declared" ] && [ "$declared" != "$tools" ]; then
    bad "$base: aif:meta says tools '$declared', the runner is given the frontmatter's '$tools'"
    continue
  fi
  case ",$tools," in
    *,Bash,*)
      ok "$base: $tools"
      continue
      ;;
  esac
  # Numbered as lines of the file, not of the body, since the file is what
  # gets edited.
  open="$(awk '/^-->$/ { print NR; exit }' "$f")"
  runs="$(aif_meta_body "$f" |
    grep -nE '(^[[:space:]]*(([0-9]+\.|[-*])[[:space:]]+)?|[.!?][[:space:]]+)(Run|Re-run|Execute)[[:space:]]' || true)"
  if [ -z "$runs" ]; then
    ok "$base: $tools — no Bash, and its prompt orders no run"
    continue
  fi
  while IFS= read -r hit; do
    bad "$base: no Bash in '$tools', yet line $((open + ${hit%%:*})) orders a run: ${hit#*:}"
  done <<EOF
$runs
EOF
done

printf '\nhooks are executable\n'
# The one property of these files no other check covers, and the one that broke.
# Every test below invokes a hook as `/bin/bash <path>`, which works at any mode —
# so the suite passed for a hook the runner could not execute. Claude Code execs
# them directly, and both fail silently when it cannot (the guard is fail-open,
# meter.sh must never block a subagent), so the only symptom is missing ledger
# rows.
#
# This tests the working tree, which on a fresh clone is git's recorded mode — so
# in CI it is the committed bit that is being checked. `cp` in cmd_init preserves
# mode, so whatever is asserted here is what every install receives.
for f in "$ROOT"/sets/claude/hooks/*; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  if [ -x "$f" ]; then
    ok "$base is executable"
  else
    bad "$base is not executable — the runner execs hooks directly; it will fail silently on every event (git update-index --chmod=+x sets/claude/hooks/$base)"
  fi
done

printf '\nguard hook: station boundaries\n'
guard() { # <label> <payload> <AIF_STATION>
  printf '%s' "$2" | env "AIF_STATION=${3:-}" \
    /bin/bash "$ROOT/sets/claude/hooks/guard.sh" 2>&1
}
g() { # <label> <payload> <deny|allow> [AIF_STATION]
  local got=allow
  guard "$1" "$2" "${4:-}" | grep -q '"deny"' && got=deny
  if [ "$got" = "$3" ]; then ok "$1 → $got"; else bad "$1 → $got (wanted $3)"; fi
}
g "implement writes a test"                '{"agent_type":"aif-implement","tool_input":{"file_path":"tests/t.py"}}' deny
g "implement-careful writes a test"        '{"agent_type":"aif-implement-careful","tool_input":{"file_path":"tests/t.py"}}' deny
g "implement writes source"                '{"agent_type":"aif-implement","tool_input":{"file_path":"src/a.py"}}' allow
g "tests writes source"                    '{"agent_type":"aif-tests","tool_input":{"file_path":"src/a.py"}}' deny
# scope exempts plan-amendments.json from its denylist so an amendment is
# possible at all; without this rule an implementation could hand-write itself
# permission for anything, bypassing the caps and the required reason.
g "implement writes the amendments file"   '{"agent_type":"aif-implement","tool_input":{"file_path":"tasks/T-1/plan-amendments.json"}}' deny
g "implement writes the plan"              '{"agent_type":"aif-implement","tool_input":{"file_path":"tasks/T-1/plan.md"}}' deny
g "tests writes a test"                    '{"agent_type":"aif-tests","tool_input":{"file_path":"tests/t.py"}}' allow
g "an unrelated subagent"                  '{"agent_type":"general-purpose","tool_input":{"file_path":"tests/t.py"}}' allow
g "a station via AIF_STATION (the live route)" '{"tool_input":{"file_path":"tests/t.py"}}' deny implement
g "payload beats a stale environment"      '{"agent_type":"aif-tests","tool_input":{"file_path":"tests/t.py"}}' allow implement
# Every subagent carries an agent_type, and only the foundry's own names are
# stations: a project's agent that happens to be called `tests` or `plan`, or
# a general-purpose one, is not policed in a plain session (DEFECTS-8 #3).
g "a project's own agent named tests writes source" '{"agent_type":"tests","tool_input":{"file_path":"src/a.py"}}' allow
g "a project's own agent named plan writes a test"  '{"agent_type":"plan","tool_input":{"file_path":"tests/t.py"}}' allow
g "a code-reviewer subagent runs git checkout"      '{"agent_type":"code-reviewer","tool_name":"Bash","tool_input":{"command":"git checkout -b x"}}' allow
g "a general-purpose subagent runs git stash list"  '{"agent_type":"general-purpose","tool_name":"Bash","tool_input":{"command":"git stash list"}}' allow
g "a project's agent named tests runs the suite"    '{"agent_type":"tests","tool_name":"Bash","tool_input":{"command":"npm test"}}' allow
g "…but inside a station's process it is the station" '{"agent_type":"general-purpose","tool_name":"Bash","tool_input":{"command":"npm test"}}' deny tests
# The contract: the plan station writes the plan and the skeleton, not the
# tests and not the rest of the ticket's record (docs/REBUILD-4.md §2.1).
g "plan writes the plan"                   '{"agent_type":"aif-plan","tool_input":{"file_path":"tasks/T-1/plan.md"}}' allow
g "plan writes a skeleton"                 '{"agent_type":"aif-plan","tool_input":{"file_path":"src/new/module.ts"}}' allow
g "plan writes a test"                     '{"agent_type":"aif-plan","tool_input":{"file_path":"tests/t.py"}}' deny
g "plan writes the lock"                   '{"agent_type":"aif-plan","tool_input":{"file_path":"tasks/T-1/tests.lock.json"}}' deny
# Each station's note is the one file under tasks/ it may write.
g "tests writes its note"                  '{"agent_type":"aif-tests","tool_input":{"file_path":"tasks/T-1/tests.note.json"}}' allow
g "tests writes the implementer's note"    '{"agent_type":"aif-tests","tool_input":{"file_path":"tasks/T-1/implement.note.json"}}' deny
g "implement writes its note"              '{"agent_type":"aif-implement","tool_input":{"file_path":"tasks/T-1/implement.note.json"}}' allow
g "implement writes the tests' note"       '{"agent_type":"aif-implement","tool_input":{"file_path":"tasks/T-1/tests.note.json"}}' deny

printf '\nguard hook: the tests station runs one command\n'
# Its Bash is for `aif _verify <ID>` and nothing else — and this rule fails
# CLOSED, unlike the commit rule, because the tool exists only for this.
b() { # <label> <command> <deny|allow> <AIF_STATION>
  g "$1" "$(jq -nc --arg c "$2" '{tool_name:"Bash",tool_input:{command:$c}}')" "$3" "$4"
}
b "tests: aif _verify"                     'aif _verify OPES-69' allow tests
b "tests: aif _verify --dry"               'aif _verify OPES-69 --dry' allow tests
b "tests: aif _verify, then more"          'aif _verify OPES-69 && npx jest' deny tests
b "tests: the suite itself"                'npx jest src/x.test.ts' deny tests
b "tests: an install"                      'npm install left-pad' deny tests
b "tests: a type-checker"                  'npx tsc --noEmit' deny tests
b "implement: the suite"                   'npx jest' allow implement
b "implement: a commit"                    'git commit -am wip' deny implement
b "plain session: anything"                'npm install left-pad' allow ""

printf '\nguard hook: a plain session is not policed\n'
# The guard binds to a STATION, not to a session. A project with aif installed
# is still an ordinary project, and a `claude` in it must find its Write tool
# exactly as it would anywhere. The orchestrator ban that used to live here
# went with the orchestrator: there is no session that dispatches stations any
# more, so there is no session to police.
g "plain session writes source"            '{"tool_input":{"file_path":"src/a.py"}}' allow ""
g "plain session writes a test"            '{"tool_input":{"file_path":"tests/t.py"}}' allow ""
g "plain session writes a plan"            '{"tool_input":{"file_path":"tasks/T-1/plan.md"}}' allow ""
g "plain session edits a gate"             '{"tool_input":{"file_path":".aif/gates/green.sh"}}' allow ""

printf '\nevery runner template has its stack fragment, and the other way round\n'
# A runner the set knows is two files: project.templates/<r>.json, which
# `aif project init` copies, and stacks/<r>.md, which the worker appends to
# the plan and tests stations' prompts for a project of that kind — the prose
# twin of the template's failure_classes (docs/REBUILD-4.md §6). One without
# the other is a runner whose stations work from general rules while the
# template promises otherwise, or a fragment nothing ever selects.
TEMPLATES="$ROOT/sets/claude/project.templates"
STACKS="$ROOT/sets/claude/stacks"
for t in "$TEMPLATES"/*.json; do
  [ -f "$t" ] || continue
  r="$(basename "$t" .json)"
  if [ -f "$STACKS/$r.md" ]; then
    ok "$r: template and fragment"
  else
    bad "$r: project.templates/$r.json has no stacks/$r.md — its stations would work from general rules"
  fi
  kind="$(jq -r '.test.kind // ""' "$t")"
  [ "$kind" = "$r" ] ||
    bad "$r: the template records test.kind \"$kind\" — the fragment is chosen by that field, and it must name the template"
done
for s in "$STACKS"/*.md; do
  [ -f "$s" ] || continue
  r="$(basename "$s" .md)"
  [ -f "$TEMPLATES/$r.json" ] ||
    bad "$r: stacks/$r.md has no project.templates/$r.json — nothing would ever select it"
  # The two facts every fragment is appended to carry: the marker a skeleton
  # throws, as the gates spell it, and the tests station's one command.
  grep -qF 'aif: not implemented' "$s" ||
    bad "$r: stacks/$r.md never names the marker 'aif: not implemented'"
  grep -qF 'aif _verify' "$s" ||
    bad "$r: stacks/$r.md never names the tests station's command, aif _verify"
  [ "$(head -1 "$s" | cut -c1-2)" = "# " ] ||
    bad "$r: stacks/$r.md does not open with a title — it is appended after a station's instructions and has to announce itself"
done

printf '\nthe junit parser reads what pytest writes\n'
# junit.py turns a report into per-test rows and verify-red matches each row's
# `file` against the test files the plan declared. pytest writes @file only
# under junit_family=xunit1; the xunit2 schema has no such attribute, pytest
# filters it out, and xunit2 has been the default since pytest 6.0 — so on any
# current project the file has to come back out of the dotted @classname. Get
# that wrong and verify-red does not complain, it goes blind: no row matches a
# declared test, every result looks pre-existing, and the gate certifies a red
# it never saw.
if aif_have python3; then
  jtmp="$(mktemp "${TMPDIR:-/tmp}/aif-junit-XXXXXX")"
  je() { # <label> <testcase xml> <the file junit.py should resolve>
    local got
    printf '<testsuites><testsuite name="pytest">%s</testsuite></testsuites>' "$2" >"$jtmp"
    got="$(python3 "$ROOT/sets/claude/gates/junit.py" "$jtmp" | jq -r '.[0].file')"
    if [ "$got" = "$3" ]; then ok "$1"; else bad "$1: got '$got', wanted '$3'"; fi
  }
  je "xunit2: the file comes back out of the classname" \
    '<testcase classname="tests.test_users" name="test_empty"/>' \
    "tests/test_users.py"
  je "xunit2: the class in the id is not a directory" \
    '<testcase classname="tests.api.test_users.TestList" name="test_paged[2-3]"/>' \
    "tests/api/test_users.py"
  je "xunit1: a report that carries @file is believed over the guess" \
    '<testcase classname="tests.test_users" file="src/elsewhere.py" name="test_empty"/>' \
    "src/elsewhere.py"
  je "a file that would not import names itself in @name" \
    '<testcase classname="" name="tests.test_broken"><error message="collection failure">SyntaxError</error></testcase>' \
    "tests/test_broken.py"
  je "another runner's classname does not become a python path" \
    '<testcase classname="Login flow" name="shows an error"/>' \
    ""
  rm -f "$jtmp"
else
  printf '  · python3 is not installed — the junit parser is unchecked here\n'
fi

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'set: ok\n'
else
  printf 'set: %s failure(s)\n' "$fails"
  exit 1
fi
