#!/usr/bin/env bash
#
# PreToolUse guard. Denies a writer from writing where it must not:
#
#   - the implement station may not touch tests, the test station may not touch
#     implementation — a test being what the plan's files.tests declares, or
#     what is named like one;
#   - no station writes .aif/, .claude/ or tasks/, its own file there aside:
#     they are how a ticket is judged and recorded (docs/DEFECTS.md 13.10).
#
# Which station is running arrives by one of two routes, and both are live:
#
#   - agent_type in the hook payload, when a station runs as a SUBAGENT. No
#     path in the foundry takes that route today; it is kept because a second
#     runner may, and because it is the more precise signal when present. Only
#     the foundry's own names count — `aif-plan`, `aif-tests`, `aif-implement`
#     and its tier variants. EVERY subagent carries an agent_type —
#     general-purpose, Explore, any agent a project defines — and for one
#     release each of them was read as a station: a plain session's
#     general-purpose subagent lost `git stash list` to the commit rule, and a
#     project's own agent named `tests` was held to the tests station in full
#     (docs/DEFECTS.md 8.3).
#   - AIF_STATION in the environment, exported by `aif work` around the
#     station's `claude -p`. This is the LIVE route: the worker runs each
#     station as its own headless process, so the marker that process inherits
#     is what says which station it is.
#
# The payload wins when it names a foundry agent: it describes the call
# actually being made, whereas an inherited environment variable describes an
# ancestor. Another agent's name says nothing about a station, and the
# environment then decides — a subagent spawned inside a station's process is
# held to that station.
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
# A name without the prefix is somebody else's agent, not a station.
agent="$(printf '%s' "$payload" | jq -r '.agent_type // ""' 2>/dev/null)"
station=""
case "$agent" in
  aif-*)
    station="${agent#aif-}"
    station="${station%-routine}"
    station="${station%-careful}"
    ;;
esac
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

# Bash. Two rules, and the second is the one the tests station's whole
# executable capability rests on.
#
# One: a station does not commit. The worker seals each admitted station
# itself, and a station that commits moves HEAD under the gates — which used
# to empty scope's diff outright (docs/DEFECTS.md 3.8). The gates now judge
# against the baseline the worker recorded, so this is the speed bump in front
# of that fix, not the fix: it matches the obvious spellings and fails OPEN on
# anything cleverer, and says so here rather than pretending to parse shell.
#
# Two: the tests station may run exactly one thing — `aif _verify <ID>`, the
# verify-red gate over its own files, which freezes nothing. That is its
# execute-and-repair loop (docs/REBUILD-4.md §2.2), and it is all it gets: not
# the suite directly, not a type-checker, not a package manager. Unlike the
# first rule this one fails CLOSED — anything that is not that one command is
# denied — because the station has Bash only for this, and a hook that let a
# second spelling through would hand it the shell. The worker grants the tool
# only after `aif doctor --probe` has watched this hook deny a command in a
# spawned run (docs/FINDINGS.md #21).
if [ "$(printf '%s' "$payload" | jq -r '.tool_name // ""' 2>/dev/null)" = "Bash" ]; then
  cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)"
  if [ "$station" = "tests" ]; then
    # The whole command, start to end: `aif _verify`, a ticket id, an optional
    # --dry, nothing chained before or after it.
    if printf '%s' "$cmd" | grep -qE '^[[:space:]]*aif[[:space:]]+_verify[[:space:]]+[A-Za-z0-9_-]+([[:space:]]+--dry)?[[:space:]]*$'; then
      exit 0
    fi
    deny "the tests station runs one command: aif _verify <TICKET> — the verify-red gate over the files you wrote, which prints every complaint the freeze would and freezes nothing. Not the suite, not a type-checker, not an install. Write the tests, run that, read it, fix, run it again."
  fi
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

# Normalise to a repo-relative path when the tool passed an absolute one —
# spelled through $PWD, or through the physical path: on macOS a project
# under /var or /tmp is /private/var or /private/tmp to every tool that
# resolves it, and a station's declared file written that way read as no
# path of the project's at all (docs/DEFECTS.md 13.10).
rel="$path"
here_p="$(pwd -P 2>/dev/null)" || here_p="$PWD"
case "$path" in
  "$PWD"/*) rel="${path#"$PWD"/}" ;;
  "$here_p"/*) rel="${path#"$here_p"/}" ;;
esac

# A test by its name or its place. `__tests__/` is jest's own root — the jest
# template's (docs/DEFECTS.md 13.10). The gates' aif_g_test_path is the same
# rule; this copy is the hook's, which cannot source the gates.
is_test() {
  case "$1" in
    tests/* | test/* | __tests__/* | */tests/* | */test/* | */__tests__/*) return 0 ;;
    *_test.* | *test_*.py | *.test.* | *.spec.*) return 0 ;;
  esac
  return 1
}

# The ticket being built, and what its plan declares as tests — files.tests:
# the tests, and the support files they need — a manual mock, a test util, a
# fixture — whatever their names. `aif work` exports AIF_TICKET beside
# AIF_STATION; the plan is read from the project the station runs in, the
# first aif:meta block, as the gates read it (the awk is _lib.sh's aif_g_meta,
# copied: hooks cannot source the gates). With no ticket, or no plan yet, a
# test is what its name says, as before (docs/DEFECTS.md 13.10).
ticket="${AIF_TICKET:-}"
case "$ticket" in
  *[!A-Za-z0-9_.-]* | .*) ticket="" ;;
esac
declared=""
if [ -n "$ticket" ] && [ -f "$PWD/tasks/$ticket/plan.md" ]; then
  declared="$(awk '
    { sub(/\r$/, "") }
    /^<!-- aif:meta$/ && !seen { inblock = 1; seen = 1; next }
    inblock && /^-->$/         { inblock = 0; next }
    inblock                    { print }
  ' "$PWD/tasks/$ticket/plan.md" | jq -r '.files.tests[]? // empty' 2>/dev/null)"
fi
is_declared() {
  [ -n "$declared" ] || return 1
  printf '%s\n' "$declared" | grep -qxF -- "$1"
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
# Each station's own note is the one file under tasks/ it may write: a
# structured way to say what its artifact cannot — "this criterion is already
# built", "this frozen test is wrong", "the contract cannot hold this" — read
# by the gates and the worker rather than guessed from a closing message. The
# plan station's is the plan itself.
own_output() { # <rel> — rc 0 when it is this station's own file under tasks/
  local f
  case "$station" in
    plan) f=plan.md ;;
    tests) f=tests.note.json ;;
    implement) f=implement.note.json ;;
    *) return 1 ;;
  esac
  if [ -n "$ticket" ]; then
    [ "$1" = "tasks/$ticket/$f" ]
    return
  fi
  case "$1" in
    tasks/*/"$f") return 0 ;;
  esac
  return 1
}

# .aif/, .claude/ and tasks/ are closed to every station's Write and Edit, its
# own file under tasks/ aside. They hold how this ticket is judged and what it
# did: the gates (.aif/gates), the test command, checks, failure classes and
# caps (.aif/project.json), this guard and its registration (.aif/hooks,
# .claude/settings.json), the stations' instructions (.claude/agents), the
# tickets' records. A station that could edit them could change how it is
# judged — and the plan station is judged by the plan gate alone, which reads
# its manifest, not the tree: whatever it wrote there was committed with the
# plan (`git add -A`). Only scope held them, and only against the implement
# station (docs/DEFECTS.md 13.10).
case "$rel" in
  .aif/* | .claude/* | tasks/*)
    if ! own_output "$rel"; then
      case "$station" in
        plan) deny "the plan station writes tasks/<TICKET>/plan.md and the skeleton files its manifest names. The rest of the ticket's record, and .aif/ and .claude/ — the gates, the project's config, the hooks, the stations' instructions — are how this ticket is judged and recorded, and no station writes them; a ticket that needs them changed is a question for the human (needs_decision)." ;;
        tests) deny "the test station writes tests only — the files the plan's files.tests declares, and files named like tests — and tasks/<TICKET>/tests.note.json for what it cannot test. .aif/, .claude/ and the rest of tasks/ are how this ticket is judged and recorded; no station writes them." ;;
        implement)
          # Including — especially — plan-amendments.json. scope exempts that one
          # file from its denylist so an amendment can be made at all, which would
          # otherwise let an implementation hand-write itself permission for
          # anything. `aif _amend-plan` is the way in: it refuses tests and
          # pipeline paths, requires a reason, and is capped.
          deny "the ticket's own record — the ticket, the plan, the ledger, the run — and .aif/ and .claude/ — the gates, the project's config, the hooks, the stations' instructions — are not yours to edit; you write code. To widen the plan's file manifest for something it could not foresee, run: aif _amend-plan <TICKET> <path> '<why>'. It is capped and recorded, and a reviewer sees it next to the plan. If the ticket needs the pipeline itself changed, say so in your note, tasks/<TICKET>/implement.note.json." ;;
        *) deny ".aif/, .claude/ and tasks/ are how a ticket is judged and recorded; no station writes them." ;;
      esac
    fi
    ;;
esac

case "$station" in
  plan)
    # The plan station writes the plan and the CONTRACT: the skeleton of every
    # module the plan creates, and a new export's signature in a module it
    # changes. Not the tests, which are the next station's — nor a support
    # file its own plan declares for them.
    if is_test "$rel" || is_declared "$rel"; then
      deny "the plan station writes the plan and the contract — the skeleton of what the tests will import — not the tests, nor the mocks and fixtures files.tests declares for them. The tests station writes those, against your skeleton."
    fi
    ;;
  implement)
    if is_test "$rel" || is_declared "$rel"; then
      deny "the tests are frozen by verify-red — files.tests, mocks and fixtures included. If a test is wrong, do not edit it — say so in tasks/<TICKET>/implement.note.json (tests_wrong: [{ test, because }]); the tests station reads the claim without the implementation in view."
    fi
    ;;
  tests)
    # A declared path, whatever its name — the plan's files.tests is the
    # tests and the support files they need: a manual mock in __mocks__/, a
    # test util, a fixture outside tests/, each refused by name before
    # (docs/DEFECTS.md 13.10) — a test by its name, or the station's note.
    if ! is_test "$rel" && ! is_declared "$rel" && ! own_output "$rel"; then
      deny "the test station writes tests only — the files the plan's files.tests declares, and files named like tests — and tasks/<TICKET>/tests.note.json for what it cannot test. Implementation belongs to the implement station; the contract is the plan's. Write the failing tests against the skeleton, and let the code come later. A mock or a fixture the tests need is one the plan declares."
    fi
    ;;
esac

exit 0
