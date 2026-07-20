#!/usr/bin/env bash
#
# Gate: spec-approve — did a human accept this exact spec?
#
# The one gate with no machine backstop, because the thing it verifies — that a
# person judged the spec complete — is not machine-decidable by construction.
# It checks the RECORD of that judgement: approval.json, bound to the spec's
# bytes, and marked as having been made at a real terminal.
#
# `tty: true` is the load-bearing field. `aif approve` writes it only when
# stdin is a terminal, and an agent's Bash tool is not a terminal. That is a
# genuine capability boundary rather than a pattern match — though a determined
# agent could allocate a pty, so it is a speed bump on the lazy path, not a
# security boundary. See docs/FINDINGS.md.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source-path=SCRIPTDIR source=_lib.sh
. "$here/_lib.sh"

aif_g_need jq

work="${1:-}"
[ -n "$work" ] || aif_g_error "usage: spec-approve.sh <work-dir>"

spec="$work/spec.md"
approval="$work/approval.json"

[ -f "$spec" ] || aif_g_error "spec.md missing"
[ -f "$approval" ] || aif_g_reject "not approved — no approval.json (run: aif approve)"

if ! jq -e . "$approval" >/dev/null 2>&1; then
  aif_g_error "approval.json is not valid JSON"
fi

spec_hash="$(aif_g_sha256 "$spec")"
spec_meta="$(aif_g_meta_or_die "$spec" "spec.md")" || exit $?
spec_assumptions="$(printf '%s' "$spec_meta" | jq -c '[.assumptions[]?.id] | sort')"

violations="$(
  jq -r \
    --arg spec_hash "$spec_hash" \
    --argjson spec_assumptions "$spec_assumptions" '
    [
      (if .subject_sha256 != $spec_hash
        then "approval is for a different spec — it changed since it was approved; re-approve"
        else empty end),
      (if (.tty // false) != true
        then "approval.tty is not true — approval was not made at a terminal"
        else empty end),
      (if (.approver // "") == "" then "approval.approver is empty" else empty end),
      (if (.at // "") == "" then "approval.at is empty" else empty end),
      # The human approved a set of assumptions; it must equal the set now in
      # the spec. A spec that grew an assumption after approval is not approved.
      (if ((.approved_assumptions // []) | sort) != $spec_assumptions
        then "approved assumptions do not match the spec — re-approve after the change"
        else empty end)
    ] | .[]
  ' "$approval" 2>&1
)" || aif_g_error "spec-approve: jq failed — $violations"

aif_g_report "$violations" "approval"

printf 'spec-approve: approved by %s\n' "$(jq -r '.approver' "$approval")"
