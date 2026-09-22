#!/usr/bin/env bash
#
# PreToolUse guard. Denies a writer from writing where it must not:
#
#   - the implement station may not touch tests, the test station may not touch
#     implementation.
#
# Which station is running arrives by one of two routes, and both are live:
#
#   - agent_type in the hook payload, when a station runs as a SUBAGENT. No
#     path in the foundry takes that route today; it is kept because a second
#     runner may, and because it is the more precise signal when present.
#   - AIF_STATION in the environment, exported by `aif work` around the
#     station's `claude -p`. This is the LIVE route: the worker runs each
#     station as its own headless process, so the marker that process inherits
#     is what says which station it is.
#
# The payload wins when both are present: it describes the call actually being
# made, whereas an inherited environment variable describes an ancestor.
#
# There used to be a third rule — an orchestrator session may not write product
# code — guarding a `claude` session that dispatched the stations as subagents
# while a human watched. There is no such session now: the worker is a
# subprocess and the only writers are stations, so the rule went with it.
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

# Not a station: nothing to guard. This is the ordinary case — a project with
# aif installed is still an ordinary project, and a plain `claude` in it must
# not find its Write tool policed.
[ -n "$station" ] || exit 0

deny() {
  # PreToolUse deny: the JSON form, so the reason reaches the model.
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
    "$(printf '%s' "$1" | jq -R .)"
  exit 0
}

# Bash, one narrow rule: a station does not commit. The worker seals each
# admitted station itself, and a station that commits moves HEAD under the
# gates — which used to empty scope's diff outright (docs/DEFECTS-3.md #8).
# The gates now judge against the baseline the worker recorded, so this is
# the speed bump in front of that fix, not the fix: it matches the obvious
# spellings and fails OPEN on anything cleverer, and says so here rather than
# pretending to parse shell.
if [ "$(printf '%s' "$payload" | jq -r '.tool_name // ""' 2>/dev/null)" = "Bash" ]; then
  cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)"
  # At a command position only — the start of the line, or after ; & | — so
  # that `echo git commit` and a message quoting the words are not denied. A
  # subshell or a backtick spelling walks past this on purpose: catching it
  # would mean parsing shell, and the gates behind this no longer need it.
  if printf '%s' "$cmd" | grep -qE '(^|[;&|])[[:space:]]*git[[:space:]]+(commit|stash|reset|rebase|merge|push|checkout|switch|restore)([[:space:]]|$)'; then
    deny "a station does not commit, reset or switch branches — the worker commits each admitted station itself, and a commit from here moves the baseline the gates judge you against. Leave the tree as it is; write the code."
  fi
  exit 0
fi

path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
[ -n "$path" ] || exit 0

# Normalise to a repo-relative path when the tool passed an absolute one.
rel="$path"
case "$path" in
  "$PWD"/*) rel="${path#"$PWD"/}" ;;
esac

is_test() {
  case "$1" in
    tests/* | test/* | */tests/* | */test/*) return 0 ;;
    *_test.* | *test_*.py | *.test.* | *.spec.*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# The station boundaries. Honest limits, since a guard that oversells itself is
# worse than none:
#   - this matches the Write and Edit tools only. `bash -c 'echo … > src/f.py'`
#     walks straight past it. Matching Bash would mean parsing shell, which is
#     fragile enough to fail open in ways nobody notices.
#   - the real backstop for code is scope, which diffs against the last commit
#     and rejects any file the plan did not name, whoever wrote it, and green,
#     which re-hashes the frozen test tree. This hook exists so the
#     honest-but-helpful path is closed early and BY NAME — a model told only
#     "no" gets creative; a model told "no, do X instead" does X.
case "$station" in
  implement)
    if is_test "$rel"; then
      deny "the tests are frozen by verify-red. If a test is wrong, do not edit it — stop and say so; the ticket goes back to the analyst to have its criteria revised."
    fi
    case "$rel" in
      tasks/*)
        # Including — especially — plan-amendments.json. scope exempts that one
        # file from its denylist so an amendment can be made at all, which would
        # otherwise let an implementation hand-write itself permission for
        # anything. `aif _amend-plan` is the way in: it refuses tests and
        # pipeline paths, requires a reason, and is capped.
        deny "the ticket's own record — the ticket, the plan, the ledger, the run — is not yours to edit; you write code. To widen the plan's file manifest for something it could not foresee, run: aif _amend-plan <TICKET> <path> '<why>'. It is capped and recorded, and a reviewer sees it next to the plan."
        ;;
    esac
    ;;
  tests)
    if ! is_test "$rel"; then
      deny "the test station writes tests only. Implementation belongs to the implement station — write the failing tests, and let the code come later."
    fi
    ;;
esac

exit 0
