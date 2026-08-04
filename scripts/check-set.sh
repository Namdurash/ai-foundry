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
  [ -n "$meta" ] || continue # not a station (aif-ticket-critic)

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
      # do, and the orchestrator picks by the spec's risk.
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

printf '\nguard hook routes on the payload, then the legacy environment\n'
guard() { printf '%s' "$2" | env "AIF_STATION=${3:-}" /bin/bash "$ROOT/sets/claude/hooks/guard.sh" 2>&1; }
g() { # <label> <payload> <deny|allow> [AIF_STATION]
  local got=allow
  guard "$1" "$2" "${4:-}" | grep -q '"deny"' && got=deny
  if [ "$got" = "$3" ]; then ok "$1 → $got"; else bad "$1 → $got (wanted $3)"; fi
}
g "implement writes a test"                '{"agent_type":"aif-implement","tool_input":{"file_path":"tests/t.py"}}' deny
g "implement-careful writes a test"        '{"agent_type":"aif-implement-careful","tool_input":{"file_path":"tests/t.py"}}' deny
g "implement writes source"                '{"agent_type":"aif-implement","tool_input":{"file_path":"src/a.py"}}' allow
g "tests writes source"                    '{"agent_type":"aif-tests","tool_input":{"file_path":"src/a.py"}}' deny
g "tests writes a test"                    '{"agent_type":"aif-tests","tool_input":{"file_path":"tests/t.py"}}' allow
g "main session, no agent_type"            '{"tool_input":{"file_path":"tests/t.py"}}' allow
g "an unrelated subagent"                  '{"agent_type":"general-purpose","tool_input":{"file_path":"tests/t.py"}}' allow
g "legacy claude -p via AIF_STATION"       '{"tool_input":{"file_path":"tests/t.py"}}' deny implement
g "payload beats a stale environment"      '{"agent_type":"aif-tests","tool_input":{"file_path":"tests/t.py"}}' allow implement

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'set: ok\n'
else
  printf 'set: %s failure(s)\n' "$fails"
  exit 1
fi
