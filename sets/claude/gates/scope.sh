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
[ -d "$root/.git" ] || aif_g_error "scope needs git — the baseline is the last committed station"

plan_meta="$(aif_g_meta_or_die "$plan" "plan.md")" || exit $?
allowed="$(printf '%s' "$plan_meta" | jq -r '((.files.create // []) + (.files.change // []))[]')"
test_roots="$(jq -r '.test.roots[]?' "$project")"
max_diff="$(jq -r '.limits.diff_lines_max // 400' "$project")"

# Paths no implementation may touch, whatever the plan says. Anchored so they
# match from the repo root only.
denylist='^\.aif/|^\.claude/|^\.github/|^\.gitlab-ci|^project\.json$|^\.aif/project\.json$|^\.gitignore$|(^|/)package-lock\.json$|(^|/)yarn\.lock$|(^|/)poetry\.lock$|(^|/)Cargo\.lock$|(^|/)go\.sum$'

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

viol=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if printf '%s' "$p" | grep -qE "$denylist"; then
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
added_removed="$(git -C "$root" diff --numstat HEAD 2>/dev/null | awk '{a+=$1; r+=$2} END{print a+r+0}')"
if [ "${added_removed:-0}" -gt "$max_diff" ]; then
  aif_g_reject "the change is $added_removed lines, over the limit of $max_diff — too large for the ticket, or out of scope"
fi

printf 'scope: change confined to the plan (%s lines)\n' "${added_removed:-0}"
