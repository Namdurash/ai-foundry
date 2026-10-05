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
aif_integrate_take() {
  local dir="$1" p="$2" keep="$3" stage=2
  [ "$keep" = ours ] || stage=3
  if git -C "$dir" ls-files -u -- "$p" 2>/dev/null | awk -v s="$stage" '$3 == s { f = 1 } END { exit !f }'; then
    git -C "$dir" checkout "--$keep" -- "$p" >/dev/null 2>&1 &&
      git -C "$dir" add -- "$p" >/dev/null 2>&1
  else
    git -C "$dir" rm -q -- "$p" >/dev/null 2>&1
  fi
}
