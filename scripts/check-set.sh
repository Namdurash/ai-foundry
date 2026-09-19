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
