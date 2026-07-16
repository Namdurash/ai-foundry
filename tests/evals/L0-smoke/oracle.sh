#!/usr/bin/env bash
#
# Runs with cwd set to the disposable working directory, after the agent has
# finished. Exit 0 means pass. $AIF_RESULT_JSON points at the run envelope.
#
# An oracle must be deterministic. "Looks right" is not an oracle; "the file
# contains OK" is.

set -uo pipefail

if [ ! -f hello.txt ]; then
  echo "hello.txt was not created"
  exit 1
fi

# $(cat) strips trailing newlines, so this tolerates the model adding one.
got="$(cat hello.txt)"
if [ "$got" != "OK" ]; then
  echo "hello.txt contains '${got}', expected 'OK'"
  exit 1
fi
