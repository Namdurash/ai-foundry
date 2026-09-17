#!/usr/bin/env bash
#
# Gate: scope — did the implementation change only what the plan allowed?
#
# green proves the tests pass. That is not enough: a passing suite says nothing
# about the 2000 lines changed elsewhere to get there. scope bounds the blast
# radius to the files the plan named, plus a denylist that holds regardless of
# what the plan says — the pipeline's own machinery, config, and CI must never be
# edited by an implementation, even one the plan wrongly permitted.
#
# The baseline is the last commit, which aif made when the tests station passed.
# So the diff is exactly what the implement station did.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source-path=SCRIPTDIR source=_lib.sh
. "$here/_lib.sh"

aif_g_need jq
aif_g_need git

work="${1:-}"
[ -n "$work" ] || aif_g_error "usage: scope.sh <work-dir>"

plan="$work/plan.md"
project="$(aif_g_project "$work")" || exit $?
root="$(dirname "$(dirname "$project")")"

[ -f "$plan" ] || aif_g_error "plan.md missing"
# -e: a git worktree has a .git FILE, and the worker runs in one.
[ -e "$root/.git" ] || aif_g_error "scope needs git — the baseline is the last committed station"

plan_meta="$(aif_g_meta_or_die "$plan" "plan.md")" || exit $?
allowed="$(printf '%s' "$plan_meta" | jq -r '((.files.create // []) + (.files.change // []))[]')"

# Amendments: paths the implementation was allowed to add to the manifest at run
# time, through `aif _amend-plan`, each with a reason. The escape hatch for what
# the plan could not foresee — an import that pulls in a neighbour, a handler
# that has to be registered somewhere unnamed.
#
# In a separate file rather than in plan.md because tests.lock.json binds to plan.md's
# bytes: amending the plan itself would invalidate the frozen tests, and green
# would reject the implementation the amendment existed to permit.
#
# Bound to the plan's hash, so a re-planned ticket does not inherit permissions
# nobody granted it. And printed below, always — a widened manifest that nobody
# sees is the same as no manifest.
amend_file="$work/plan-amendments.json"
amended=""
if [ -f "$amend_file" ] &&
  [ "$(jq -r '.plan_sha256 // ""' "$amend_file" 2>/dev/null)" = "$(aif_g_sha256 "$plan")" ]; then
  amended="$(jq -r '.amendments[]?.path // empty' "$amend_file" 2>/dev/null)"
fi
if [ -n "$amended" ]; then
  allowed="$(printf '%s\n%s' "$allowed" "$amended")"
fi
test_roots="$(jq -r '.test.roots[]?' "$project")"
max_diff="$(jq -r '.limits.diff_lines_max // 400' "$project")"

# Paths no implementation may touch, whatever the plan says. The list itself is
# AIF_G_DENYLIST in _lib.sh — one list, shared with plan-form, which refuses
# the same paths at plan time so this gate stays the backstop rather than the
# first place the disagreement surfaces.
#
# tasks/ is on that list and is load-bearing: it holds the ticket, the spec, the
# plan and the ledger for every ticket including this one. An implementation
# permitted to write there could widen its own plan's file list — the very thing
# this gate exists to check — or edit the record of what it did. It is the
# pipeline's own machinery, and it lives at the project root rather than under
# .aif/ (see lib/paths.sh), so it needs naming separately.
denylist="$AIF_G_DENYLIST"

in_set() {
  # is $1 present in the newline list on stdin?
  local needle="$1" line
  while IFS= read -r line; do
    [ "$line" = "$needle" ] && return 0
  done
  return 1
}

under_test_root() {
  local p="$1" r
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$p" in
      "$r"/*) return 0 ;;
    esac
  done <<EOF
$test_roots
EOF
  return 1
}

# What the implement station changed: tracked modifications and deletions since
# the last commit, plus new untracked files.
changed="$(git -C "$root" diff --name-only HEAD 2>/dev/null || true)"
created="$(git -C "$root" ls-files --others --exclude-standard 2>/dev/null || true)"
deleted="$(git -C "$root" diff --name-only --diff-filter=D HEAD 2>/dev/null || true)"

# The amendments file itself is under tasks/, so the denylist would reject the
# very mechanism that exists to be used. Exempted by exact path — not the whole
# directory, which still holds the plan and the ledger this gate protects.
amend_rel="${amend_file#"$root"/}"

# The ledger too, and for the same reason: aif itself writes it. A failed
# attempt's verdicts are recorded the moment the gate rejects — between two aif
# commits — so on the retry the ledger sits modified in the very diff this gate
# reads, and the pipeline's own bookkeeping reads as the implementation editing
# its record. The hook's cost rows are staged out of the diff entirely
# (.aif/tmp/, folded in by `aif _gate`); this carve-out covers the verdicts,
# which must land when they happen or a crash loses the attempt. Tamper
# evidence does not thin: the ledger is hash-chained and committed, and the
# guard hook still refuses any station that tries to write it.
ledger_rel="${work#"$root"/}/ledger.json"

viol=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if [ "$p" = "$amend_rel" ] || [ "$p" = "$ledger_rel" ]; then
    continue
  elif printf '%s' "$p" | grep -qE "$denylist"; then
    viol="$viol
$p is off-limits to any implementation (pipeline, config, or CI)"
  elif under_test_root "$p"; then
    viol="$viol
$p is a test file — the implementation must not touch tests"
  elif ! printf '%s\n' "$allowed" | in_set "$p"; then
    viol="$viol
$p is not in the plan's create or change list"
  fi
done <<EOF
$(printf '%s\n%s\n' "$changed" "$created" | grep -v '^$' | sort -u)
EOF

# Deletions are never in the plan (it has no delete list), so any deletion is
# out of scope.
while IFS= read -r p; do
  [ -n "$p" ] || continue
  viol="$viol
$p was deleted — the plan did not authorise removing it"
done <<EOF
$deleted
EOF

aif_g_report "${viol# }" "scope"

# A green diff can still be a rewrite. Cap the size: a small model that changed
# 2000 lines to pass three tests has done something other than the ticket.
# tasks/ is excluded from the count — the ledger and the amendments file are
# machine-written bookkeeping, and rows recorded for a failed attempt must not
# eat the budget of the retry that fixes it.
added_removed="$(git -C "$root" diff --numstat HEAD -- . ":(exclude)tasks" 2>/dev/null | awk '{a+=$1; r+=$2} END{print a+r+0}')"
if [ "${added_removed:-0}" -gt "$max_diff" ]; then
  aif_g_reject "the change is $added_removed lines, over the limit of $max_diff — too large for the ticket, or out of scope"
fi

if [ -n "$amended" ]; then
  # Loudly, on the pass path. A widened manifest that only shows up when someone
  # goes looking is the same as an unwidened one being quietly ignored.
  printf 'scope: change confined to the plan AS AMENDED (%s lines, %s amendment(s))\n' \
    "${added_removed:-0}" "$(printf '%s\n' "$amended" | grep -c .)"
  jq -r '.amendments[] | "  + " + .path + ": " + .why' "$amend_file" 2>/dev/null
else
  printf 'scope: change confined to the plan (%s lines)\n' "${added_removed:-0}"
fi
