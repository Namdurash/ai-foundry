#!/usr/bin/env bash
#
# PreToolUse guard. Denies a station from writing where it must not: the
# implement station may not touch tests, the test station may not touch
# implementation.
#
# Which station is running arrives by one of two routes, and both are live:
#
#   - agent_type in the hook payload, when the station runs as a SUBAGENT. This
#     is the real signal — Claude Code puts agent_type (and agent_id) in the
#     payload only for calls originating inside a subagent, and omits the keys
#     entirely for the main session. Measured, not assumed.
#   - AIF_STATION in the environment, when the station runs as `claude -p` via
#     `aif station run`, which exports it. That path is being retired; the
#     fallback goes with it.
#
# The payload wins when both are present: it describes the call actually being
# made, whereas an inherited environment variable describes an ancestor.
#
# This is a speed bump on the lazy path, not a security boundary. green's
# hash-lock is the real arbiter — it catches a defeated oracle after the fact.
# The hook stops the honest-but-lazy model from editing a test in the first
# place, and, crucially, names the legal move so it does not escalate to a
# workaround. A model told only "no" gets creative; a model told "no, do X
# instead" does X.
#
# Runs from the project during a claude session, so it uses only POSIX tools and
# whatever jq the project has. No aif on PATH.

set -u

payload="$(cat)"

command -v jq >/dev/null 2>&1 || exit 0

# The agent's name maps to a station by dropping the aif- prefix, so a station
# is named once (in the agent's filename) rather than twice. The tier variants
# of one station — aif-implement and aif-implement-careful — are the same
# station and must be guarded identically, so the tier suffix is dropped too.
station="$(printf '%s' "$payload" |
  jq -r '.agent_type // "" | sub("^aif-"; "") | sub("-(routine|careful)$"; "")' 2>/dev/null)"
[ -n "$station" ] || station="${AIF_STATION:-}"

# Neither signal: not a station, so nothing to guard. The main session lands
# here, which is correct for this hook — bounding what the ORCHESTRATOR may
# write is a separate rule, not this one.
[ -n "$station" ] || exit 0

path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
[ -n "$path" ] || exit 0

# Normalise to a repo-relative path when the tool passed an absolute one.
rel="$path"
case "$path" in
  "$PWD"/*) rel="${path#"$PWD"/}" ;;
esac

deny() {
  # PreToolUse deny: the JSON form, so the reason reaches the model.
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
    "$(printf '%s' "$1" | jq -R .)"
  exit 0
}

is_test() {
  case "$1" in
    tests/* | test/* | */tests/* | */test/*) return 0 ;;
    *_test.* | *test_*.py | *.test.* | *.spec.*) return 0 ;;
  esac
  return 1
}

case "$station" in
  implement)
    if is_test "$rel"; then
      deny "the tests are frozen by verify-red. If a test is wrong, do not edit it — stop and report it, and the ticket returns to have its tests or spec revised."
    fi
    ;;
  tests)
    if ! is_test "$rel"; then
      deny "the test station writes tests only. Implementation belongs to the implement station — write the failing tests, and let the code come later."
    fi
    ;;
esac

exit 0
