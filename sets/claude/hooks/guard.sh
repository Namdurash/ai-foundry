#!/usr/bin/env bash
#
# PreToolUse guard. Denies a station from writing where it must not: the
# implement station may not touch tests, the test station may not touch
# implementation. Reads the tool call on stdin (JSON) and AIF_STATION from the
# environment, which the station runner exports before invoking claude.
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
station="${AIF_STATION:-}"

# Not inside an aif station run: nothing to guard.
[ -n "$station" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

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
