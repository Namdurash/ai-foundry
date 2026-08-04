#!/usr/bin/env bash
#
# Gate: spec-approve — did a human accept this exact spec?
#
# The one gate with no machine backstop, because the thing it verifies — that a
# person judged the spec complete — is not machine-decidable by construction. It
# checks the RECORD of that judgement: approval.json, bound to the spec's bytes.
#
# It used to require `tty: true`, written only when stdin was a terminal, on the
# grounds that an agent's Bash tool is not one. That was a real capability
# boundary. It is gone, deliberately: the human now approves inside the session,
# where no terminal exists to check for, and the old rule blocked the only path
# they have.
#
# What is checked instead is that the approval names HOW it was given and, for a
# chat approval, carries the user's own words. That is evidence, not proof — a
# model could write those words itself. The honest summary: everything else in
# this pipeline is verified, and this one thing is trusted. It is stated in the
# README rather than implied by a field name.

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
[ -f "$approval" ] || aif_g_reject "not approved — no approval.json (the human has not approved this spec)"

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
      # channel says how the approval was given. A pre-chat approval.json carries
      # tty:true and no channel; it stays valid, because invalidating approvals
      # that were correctly given under the older rule would be a lie about what
      # happened.
      (if (.channel // (if (.tty // false) == true then "tty" else "" end)) as $c
          | ($c != "chat" and $c != "tty")
        then "approval.channel must be chat or tty — it must say how the approval was given"
        else empty end),
      (if (.channel // "") == "chat" and ((.confirmation // "") | length) == 0
        then "a chat approval must carry the approvers own words in approval.confirmation"
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
