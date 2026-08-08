#!/usr/bin/env bash
#
# SubagentStop hook. Records what a station's subagent cost, into that ticket's
# ledger.
#
# Deliberately a shim: it forwards the payload to `aif _meter` rather than doing
# the work here. The ledger is append-only and hash-chained, and a second
# implementation of that append — in a project-local script nobody lints — would
# drift from the first and produce a chain that does not verify. One writer.
#
# That makes `aif` a requirement, unlike the gates, which run in CI with no aif
# on the box (docs/FINDINGS.md #7a). The requirement is fair here: this hook only
# has anything to do inside a session, and the supported way to open one is
# `aif run`, which means aif was on PATH a moment ago. When it is not, the hook
# says so rather than silently accounting for nothing — an accounting gap that
# announces itself is recoverable, one that does not is how a ledger ends up
# flattering.
#
# Always exits 0. A metering failure must never block a subagent from finishing;
# losing the record of work is bad, losing the work is worse.

set -u

payload="$(cat)"

if ! command -v aif >/dev/null 2>&1; then
  # shellcheck disable=SC2016 # the backticks are prose, not a substitution
  printf 'aif not on PATH — this station ran unmetered. Open the session with `aif run`.\n' >&2
  exit 0
fi

printf '%s' "$payload" | aif _meter || true
exit 0
