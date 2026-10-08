#!/usr/bin/env bash
#
# A ticket's branch and the branch it lands on, brought together as far as
# aif's own files go. Sourced by bin/aif; not meant to be executed directly.
#
# A ticket's branch carries files aif wrote and no station may touch: the
# ticket's record under tasks/<ID>/ — the ticket as it was built, the plan, the
# run, the report, the ledger — and, once a run has brought it up to the
# checkout's set (docs/DEFECTS.md 9.1), the set itself under .aif/ and
# .claude/. The branch it lands on has copies of some of those too: the
# analyst's scaffold of the same ticket, committed beside the request it came
# from, and the set the checkout runs now. When both sides changed one, git
# stopped on a conflict and the card went to a human — on aif/OPES-74 the whole
# of it was the ledger, added on both sides, the code merging clean
# (docs/DEFECTS.md 13.2).
#
# None of those is a decision. Each file has an owner, and the owner's copy is
# the one that stands:
#
#   tasks/<ID>/…       the ticket's branch: the record of what was built, and
#                      the bytes it was built from — the copy on the other
#                      side is the analyst's scaffold, or an older text, and it
#                      stays in the history
#   tasks/<other>/…    the branch it lands on: another ticket's record is that
#                      ticket's business
#   .aif/…, .claude/…  the branch it lands on: the set the checkout runs now,
#                      which is the newer of the two
#
# Code, tests and lockfiles have no such owner, and nothing here settles them
# (docs/DEFECTS.md 13.4).

# What aif_integrate_own settled and what it left, for the caller to say.
# Declared here: a merge with no conflict never calls it, and its caller reads
# them under set -u.
AIF_INTEGRATE_SETTLED=""
AIF_INTEGRATE_LEFT=""

# aif_integrate_owner <path> <ticket> — whose copy of <path> stands: "ticket"
# (the ticket's branch), "target" (the branch it lands on), or empty when the
# path is not aif's own.
aif_integrate_owner() {
  case "$1" in
    "$AIF_TASKS_DIR/$2/"*) printf 'ticket' ;;
    "$AIF_TASKS_DIR/"*) printf 'target' ;;
    .aif/* | .claude/*) printf 'target' ;;
  esac
}

# aif_integrate_own <dir> <ticket> <ours|theirs> — settle, by owner, every
# conflict of the merge in progress in <dir> that is in aif's own files. The
# third argument is the side the ticket's branch is on in this merge: theirs
# when the ticket's branch is merged into the checkout's (aif land), ours when
# the checkout's branch is merged into the ticket's.
#
# Sets AIF_INTEGRATE_SETTLED ("<path>\t<owner>" per line, staged) and
# AIF_INTEGRATE_LEFT (one path per line: conflicts that are not aif's own, or
# that could not be taken). rc 0 when nothing is left, 1 otherwise. What is
# settled stays staged either way; the caller commits the merge, or aborts it.
aif_integrate_own() {
  local dir="$1" ticket="$2" side="$3" other p owner keep tab
  tab="$(printf '\t')"
  AIF_INTEGRATE_SETTLED=""
  AIF_INTEGRATE_LEFT=""
  case "$side" in
    ours) other=theirs ;;
    theirs) other=ours ;;
    *) return 1 ;;
  esac
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    owner="$(aif_integrate_owner "$p" "$ticket")"
    case "$owner" in
      ticket) keep="$side" ;;
      target) keep="$other" ;;
      *)
        AIF_INTEGRATE_LEFT="$AIF_INTEGRATE_LEFT$p
"
        continue
        ;;
    esac
    if aif_integrate_take "$dir" "$p" "$keep"; then
      AIF_INTEGRATE_SETTLED="$AIF_INTEGRATE_SETTLED$p$tab$owner
"
    else
      AIF_INTEGRATE_LEFT="$AIF_INTEGRATE_LEFT$p
"
    fi
  done <<EOF
$(git -C "$dir" -c core.quotePath=false diff --name-only --diff-filter=U 2>/dev/null)
EOF
  [ -z "$AIF_INTEGRATE_LEFT" ]
}

# aif_integrate_take <dir> <path> <ours|theirs> — one side's copy of a
# conflicted path, staged: its content where that side has the file, its
# removal where that side removed it (a modify/delete conflict). The worker's
# sync takes a conflicted lockfile this way too, from the branch it lands on,
# and has the package manager write it again.
#
# Without the project's hooks (aif_git_own, lib/common.sh): a post-checkout
# that exits non-zero made the checkout of one side read as failed, after it
# was made, and the path was left for a station to settle (docs/DEFECTS.md
# 13.11; probed, docs/FINDINGS.md #30).
aif_integrate_take() {
  local dir="$1" p="$2" keep="$3" stage=2
  [ "$keep" = ours ] || stage=3
  if git -C "$dir" ls-files -u -- "$p" 2>/dev/null | awk -v s="$stage" '$3 == s { f = 1 } END { exit !f }'; then
    aif_git_own "$dir" checkout "--$keep" -- "$p" >/dev/null 2>&1 &&
      aif_git_own "$dir" add -- "$p" >/dev/null 2>&1
  else
    aif_git_own "$dir" rm -q -- "$p" >/dev/null 2>&1
  fi
}

# --- the land in flight --------------------------------------------------------
#
# `aif land` makes its merge in the ticket's own worktree, detached at the
# target's tip, judges it there, and moves the developer's branch only by a
# fast-forward at the end (lib/cmd_land.sh; docs/DEFECTS.md 13.5). What a stop
# leaves to put back is small and in one place — the worktree, and the
# ticket's own untracked files taken aside for the fast-forward — and the
# land's handler puts it back in about 50 ms of git. But a SIGKILL runs no
# handler, and one Ctrl-C in a review session sends the land TERM and then
# KILL 1.3–1.5 s later (docs/DEFECTS.md 15.1; docs/FINDINGS.md #28). So the
# land writes down where it is, and whoever meets the worktree or the marker
# next — the next land, the worker on that ticket, aif doctor — reads from it
# what is left to undo or finish.
#
# The marker (aif_land_marker_file, lib/paths.sh):
#
#   { ticket, pid, started_at, target, pre, branch, merge, worktree,
#     made_worktree, installed_in_worktree, keep, prepare_here, aside_dir,
#     aside: [..], state, done: [..], note, at }
#
#   state   merging — the worktree is put at the target (pre) and the branch
#             merged into it, and installed where the merge moved what the
#             worktree had installed;
#           judging — the merge is committed in the worktree (merge) and
#             judged there;
#           ff — the checkout's branch is being fast-forwarded to it, the
#             ticket's own untracked files aside in aside_dir;
#           landed — the branch is at the merge (written by the section that
#             moved it); what is left is the bookkeeping, each step in done
#             once made: note, done, release, cleanup.
#
# Nothing in it is a verdict: until `landed` the developer's branch was never
# moved, and the worktree going back to aif/<ID> is the whole of an undo.

# aif_land_marker_get <file> <jq filter> — what the marker says, raw; empty
# when there is no marker, or nothing there.
aif_land_marker_get() {
  [ -f "$1" ] || return 0
  jq -r "($2) // empty" "$1" 2>/dev/null || true
}

# aif_land_marker_set <file> <jq filter> [jq args…] — the marker rewritten
# through <filter> (from {} when there is none) and stamped with `at`, by a
# temp file beside it and a rename: a reader — the next land, aif doctor, the
# worker — never sees half of one. rc 1 when it could not be written.
aif_land_marker_set() {
  local f="$1" filter="$2" tmp at
  shift 2
  at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  tmp="$(mktemp "$f.XXXXXX" 2>/dev/null)" || return 1
  if [ -f "$f" ]; then
    jq "$@" --arg marker_at "$at" "($filter) | .at = \$marker_at" "$f" >"$tmp" 2>/dev/null
  else
    jq -n "$@" --arg marker_at "$at" "({} | $filter) | .at = \$marker_at" >"$tmp" 2>/dev/null
  fi && mv -f "$tmp" "$f" 2>/dev/null && return 0
  rm -f "$tmp"
  return 1
}

# aif_land_pid_live <pid> — rc 0 when <pid> is an `aif land` that runs: alive,
# not a zombie, its command a land's. A marker or a section file outlives the
# land that wrote it, and its pid may be handed to some other program since
# (the same reading as the run lock's, docs/DEFECTS.md 14.5).
aif_land_pid_live() {
  local st cmd
  case "${1:-}" in
    '' | *[!0-9]*) return 1 ;;
  esac
  kill -0 "$1" 2>/dev/null || return 1
  st="$(ps -o stat= -p "$1" 2>/dev/null)" || st=""
  case "$st" in
    '' | *Z*) return 1 ;;
  esac
  cmd="$(ps -o command= -p "$1" 2>/dev/null)" || return 1
  case "$cmd" in
    *"aif land"*) return 0 ;;
  esac
  return 1
}

# aif_land_worktree_back <wt> <branch> [<installed>] — the ticket's worktree
# back on its branch, as the worker left it: a merge in progress aborted, the
# branch checked out over whatever the land had there — the target's tip, a
# merge it made. <installed> 1 when the land installed in it: what is
# installed there is the merge's then, not the branch's, and the marker that
# tells the worker its install is done goes (lib/cmd_work.sh
# _aif_work_ready_worktree), so the next run installs again. Without the
# project's hooks, as all of aif's own git (aif_git_own): a post-checkout
# that exits 7 would read as a failed put-back. rc 1 when the branch could
# not be checked out there.
aif_land_worktree_back() {
  local wt="$1" branch="$2" installed="${3:-0}"
  [ -e "$wt/.git" ] || return 0
  if git -C "$wt" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    aif_git_own "$wt" merge --abort >/dev/null 2>&1 || true
  fi
  aif_git_own "$wt" checkout -q -f "$branch" >/dev/null 2>&1 || return 1
  [ "$installed" != 1 ] || rm -f "$wt/.aif/tmp/prepared"
  return 0
}
