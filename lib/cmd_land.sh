#!/usr/bin/env bash
#
# `aif land <ticket>` — the human's yes after review, as one command.
# Sourced by bin/aif; not meant to be executed directly.
#
# The worker ends with a branch and a card in Review; the human reads the
# report next to the diff and decides. Until now their yes was five things
# done by hand — merge the branch, run the suite, move the card, remove the
# worktree, release the ticket that was waiting for this one — and each was a
# step out of the product conversation they were meant to be having while the
# machine built. This is those five, in that order, with the board as the
# authority on whether a yes is allowed at all.
#
#   refuse      not the main checkout, another land running here, no branch,
#               the card not in Review, the run record not `built`, on Trello
#               a card whose text is not the ticket the run built (15.12), a
#               worker on the ticket, a worktree of another repository or off its
#               branch, uncommitted changes to files the land changes, an
#               untracked file of the developer's that it would write over,
#               --prepare with no "prepare" to run — nothing touched
#   merge       in the ticket's own worktree, .aif/worktrees/<ID>, put at the
#               checkout's tip for the length of the land: aif/<ID> merged in,
#               --no-ff so the ticket stays one commit to find. A conflict in
#               aif's own files — the ticket's record, the set — is settled by
#               owner (lib/integrate.sh); a conflict in code sends the card back
#               to Ready for the worker, which brings the branch onto this one
#               and returns it to Review (docs/DEFECTS.md 13.4)
#   install     "prepare", in that worktree, when the merge moved a manifest or
#               a lockfile against what the worker installed there, or when
#               the land had to cut the worktree itself
#   commit      the land's merge commit, made there with the project's git
#               hooks: the one commit of aif's they are for (docs/DEFECTS.md
#               13.11) — every other git call here runs without them
#   verdict     the worker's own when it judged this very tree (run.json's
#               `judged`, with this checkout's test command and checks); else
#               the suite and the green-phase checks, there (_aif_land_judge).
#               A red sends the card back to the worker the same way — but not
#               a test or a check red on the target before this ticket, nor a
#               test that passes on a re-run: those are let through and named
#               on the landing note, by the gates' own rule (13.9)
#   land        the developer's branch fast-forwarded to the merge, and nothing
#               else of theirs touched: their uncommitted work on files the
#               land does not change stays as it is
#   card        → Done with what happened as a comment; back to Ready with a
#               `sync:` comment for the worker (a conflict in code, a red on
#               the result); → Needs Human with a `land:` comment for the rest
#               — an install that failed there, git or the project's hooks
#               refusing the merge commit, a suite that could not run there
#   release     every ticket whose `depends_on` names this one, and whose other
#               dependencies are Done, moves Backlog → Ready. That is how a
#               request's slices flow without the project manager touching
#               each one
#
# Why the worktree. The land used to merge into the developer's own checkout
# and run the suite there (docs/DEFECTS.md 13.5): it refused while anything
# tracked was uncommitted, in the checkout where the human talks to the
# analyst and the product partner; it judged a merge that moved a lockfile
# against the install from before it, and went red over a package it lacked
# (6.3); it ran no checks, so two tickets that merged clean and type-checked
# apart could leave the target red for every ticket after them. The worktree
# holds what the worker installed for this branch, the project's hooks find
# their tools there, and the worker's sync already judged this very tree
# there — so most lands judge nothing at all, and the rest judge where a
# judge's install is not invasive. The developer's branch moves once, by a
# fast-forward, which needs no clean tree for the files it does not touch.
#
# And why a marker. A land between its merge and its fast-forward has nothing
# of the developer's to put back — only the worktree, back on its branch, and
# the ticket's own files taken aside for the fast-forward — and its handler
# does that in about 50 ms of git (_aif_land_stopped). But one Ctrl-C in a
# review session sends the land TERM and then SIGKILL 1.3–1.5 s later, and a
# KILL runs no handler (docs/DEFECTS.md 15.1; docs/FINDINGS.md #28). So the
# land writes down where it is (lib/integrate.sh, the land in flight), the
# fast-forward itself runs where neither signal reaches it, and the next land
# — or the worker, or aif doctor — reads what is left to undo or finish.
#
# It never runs a model and never starts a build. Exit: 0 landed · 1 refused,
# or not landed (the card and the comment say why) · 3 the environment cannot
# land anything (not a project, a worktree, the board unreachable, another
# land here, git's own lock left by a land killed in its fast-forward) · 130,
# 143 or 129 stopped by an INT, a TERM or a hang-up — before the fast-forward
# nothing landed, after it the bookkeeping is left to the next aif land.

_aif_land_usage() {
  cat <<EOF
usage: aif land <ticket> [options]

  The yes after review, as one command: merge aif/<ticket> onto this checkout's
  branch and judge the result, in the ticket's own worktree; fast-forward this
  branch to it; move the card to Done, remove the worktree and the branch, and
  release the tickets that were waiting for this one — those whose depends_on
  names it — from Backlog to Ready.

  Refused, touching nothing, unless this is the main checkout, no other land
  runs here, the branch exists, the card is in Review, the run ended built —
  on Trello, of the card's text as it is now — no worker is on it, and nothing
  uncommitted here is a file the land changes —
  your other uncommitted work stays as it is. The ticket's own files that the
  analyst left uncommitted here are taken aside to .aif/tmp/ rather than
  written over, and a conflict in aif's own files — the ticket's record under
  tasks/<ticket>/, the set under .aif/ and .claude/ — is settled by owner: the
  record is the branch's, the set is this checkout's.

  The merge is made in .aif/worktrees/<ticket>, at this branch's tip, where the
  worker installed what the branch needs, and "prepare" runs there when the
  merge moved a dependency manifest or lockfile. The worker's own verdict
  stands when it judged that very tree; otherwise the suite and the checks
  bound to "green" run there. A conflict in code, or a red, sends the card back
  to the top of Ready: the worker brings the branch onto this one, and it comes
  back to Review. The merge commit runs the project's git hooks, and a refusal
  is a human's. Stopped before the fast-forward — Ctrl-C, a TERM, the terminal
  closing over it — nothing has landed and the card stays in Review; a land
  killed outright is put back, or finished, by the next aif land.

  --no-suite         land without a verdict on the result (and no install)
  --keep             keep the worktree and the branch after landing
  --prepare          after the fast-forward, when the land moved a manifest or
                     a lockfile, run "prepare" from .aif/project.json HERE too
                     (npm ci replaces node_modules) — no verdict needs it
EOF
}

_aif_land_say() {
  printf '%s%-9s%s %s\n' "$AIF_C_DIM" "$1" "$AIF_C_RESET" "$2" >&2
}

# What a stop acts on, in globals, as the worker's handler has it: a trap fires
# with nothing but the signal's name, and on EXIT the locals may already be
# gone.
#
#   AIF_LAND_STATE   where the land is: "" (the lock alone: refusals),
#                    merging, judging, ff — the worktree and the aside to put
#                    back — section (the fast-forward runs: a signal is noted
#                    and acted on after it), installing (--prepare's install
#                    here, after the fast-forward), landed (the bookkeeping)
#   AIF_LAND_WT      the worktree, once the land has touched it
#   AIF_LAND_MARKER  the marker, once there is one (lib/integrate.sh)
AIF_LAND_ROOT=""
AIF_LAND_CARD=""
AIF_LAND_AGAIN=""
AIF_LAND_LOCK=""
AIF_LAND_MARKER=""
AIF_LAND_STATE=""
AIF_LAND_WT=""
AIF_LAND_BRANCH=""
AIF_LAND_TARGET=""
AIF_LAND_MERGE=""
AIF_LAND_INSTALLED=0
AIF_LAND_PREPARE=""
AIF_LAND_OUT=""
AIF_LAND_SIGNAL=""
AIF_LAND_SECTION=""
AIF_LAND_BACK_FAILED=0
AIF_LAND_STOPPING=0
# The ticket's own files that are untracked here and that the fast-forward
# would write over, one path per line (_aif_land_clear); what was taken aside
# of them, and where to; how many were not the bytes the branch carries (an
# empty ledger is not counted — it held nothing).
AIF_LAND_OWN=""
# The copy of the target the verdict measures a failure on, while it exists
# (_aif_land_judge, _aif_land_copy_at): removed by any stop (_aif_land_unwind).
AIF_LAND_COPY=""
AIF_LAND_ASIDE=""
AIF_LAND_ASIDE_DIR=""
AIF_LAND_ASIDE_DIFF=0

# _aif_land_unlock — the land lock released, if this process holds it.
_aif_land_unlock() {
  local lock="$AIF_LAND_LOCK"
  [ -n "$lock" ] || return 0
  AIF_LAND_LOCK=""
  [ "$(_aif_work_lock_pid "$lock")" = "$$" ] || return 0
  rm -rf "${lock:?}" 2>/dev/null || true
}

# _aif_land_unwind — every end that does not land, from a refusal after the
# merge to a stop: the ticket's own files back from aside, the worktree back
# on its branch (aif_land_worktree_back), the marker and the lock gone. The
# developer's branch was never moved, so this is the whole of an undo — about
# 50 ms of git, inside the grace a KILL gives (docs/DEFECTS.md 15.1). Safe to
# run twice; nothing in it may stop it, since it runs in the handler too.
_aif_land_unwind() {
  _aif_land_restore_aside
  # The verdict's copy of the target, when a stop came while it was measured
  # there (_aif_land_judge).
  [ -z "${AIF_LAND_COPY:-}" ] || rm -rf "${AIF_LAND_COPY:?}" 2>/dev/null || true
  AIF_LAND_COPY=""
  if [ -n "$AIF_LAND_WT" ] && [ -n "$AIF_LAND_BRANCH" ]; then
    aif_land_worktree_back "$AIF_LAND_WT" "$AIF_LAND_BRANCH" "$AIF_LAND_INSTALLED" || AIF_LAND_BACK_FAILED=1
    AIF_LAND_WT=""
  fi
  [ -z "$AIF_LAND_MARKER" ] || rm -f "$AIF_LAND_MARKER" 2>/dev/null || true
  AIF_LAND_MARKER=""
  _aif_land_unlock
  AIF_LAND_STATE=""
}

# _aif_land_back_line <ticket> — what became of the worktree, for the card and
# the terminal; empty when it went back as it should.
_aif_land_back_line() {
  [ "$AIF_LAND_BACK_FAILED" -eq 1 ] || return 0
  printf '%s/%s could not be put back on aif/%s — aif work %s puts it back before it builds.' \
    "$AIF_WORK_WORKTREES" "$1" "$1" "$1"
}

# _aif_land_fail <root> <ticket> <headline> <detail-file> <again> [<more>] —
# nothing landed: the reason on the card, the card in Needs Human, exit 1.
# <again> is the command that lands it once it is resolved. <more> follows the
# detail, on the card and here: what the install left, a better command than
# <again> when there is one.
#
# The note's first line is `land: <headline>` — a head. The project manager
# and `aif board head` route a card on the first line of the newest comment aif
# or a role wrote, without reading it as prose: the worker's every stop is a
# `blocked: <kind>`, a card the land hands back to the worker is a `sync:`.
# This note began `# <ID> — not landed`, a title, and a failed land was the one
# card in Needs Human whose first line nothing could route on
# (docs/AUTOPILOT-RESEARCH.md §4.5; docs/DEFECTS.md 14.9). The heads are listed
# in AIF_BOARD_HEADS, lib/board.sh, where the old title stays for the cards
# written before this. What the terminal prints is unchanged: there the
# headline is the error line.
#
# The worktree goes back on its branch and the lock is released before the
# card moves: a card back on the board is a card someone may take at once.
_aif_land_fail() {
  local root="$1" ticket="$2" headline="$3" detail="$4" again="$5" more="${6:-}" note target back
  target="${AIF_LAND_TARGET:-}"
  [ -n "$target" ] || target="the branch it lands on"
  _aif_land_unwind
  aif_trap_disarm
  back="$(_aif_land_back_line "$ticket")"
  note="$(mktemp "${TMPDIR:-/tmp}/aif-land-XXXXXX")"
  {
    printf 'land: %s\n' "$headline"
    if [ -s "$detail" ]; then
      printf '\n```\n'
      sed 's/\x1b\[[0-9;]*m//g' "$detail" | sed -n '1,20p'
      printf '```\n'
    fi
    [ -z "$more" ] || printf '\n%s\n' "$more"
    printf '\nNothing landed: %s was not moved, and aif/%s is untouched.%s Rework the ticket, or resolve it and run: %s\n' \
      "$target" "$ticket" "${back:+ $back}" "$again"
  } >"$note"
  (AIF_BOARD_BY="aif land" aif_board_comment "$root" "$ticket" "$note" >/dev/null) || true
  (aif_board_move "$root" "$ticket" needs_human >/dev/null) || true
  rm -f "${note:?}" "${detail:?}"
  [ -z "$AIF_LAND_OUT" ] || rm -f "$AIF_LAND_OUT"
  aif_err "$headline"
  [ -z "$more" ] || printf '%s\n' "$more" | sed '/./s/^/  /' >&2
  [ -z "$back" ] || aif_warn "$back"
  _aif_land_say "board" "$ticket → needs_human, the reason posted"
  exit 1
}

# _aif_land_requeue <root> <ticket> <headline> <detail-file> <target> [<more>]
# — nothing landed, and the card handed back to the worker, not to a human
# (docs/DEFECTS.md 13.4). A conflict in code, or a red on the result, is the
# branch not yet brought onto what it lands on: the worker brings it there in
# its worktree — the conflicts settled by the implement station, or the ticket
# built again from the target when they cannot be — and the card comes back to
# Review, to be looked at again (the user's call, 2026-10-05). It goes to the
# top of Ready, the reason in a comment whose first line is `sync:`. Exit 1.
_aif_land_requeue() {
  local root="$1" ticket="$2" headline="$3" detail="$4" target="$5" more="${6:-}" note back
  _aif_land_unwind
  aif_trap_disarm
  back="$(_aif_land_back_line "$ticket")"
  note="$(mktemp "${TMPDIR:-/tmp}/aif-land-XXXXXX")"
  {
    printf 'sync: %s\n\n' "$headline"
    printf 'Nothing landed: %s was not moved, and aif/%s is untouched. The worker brings it onto %s in its worktree — a conflict in code settled by the implement station, or the ticket built again from %s when it cannot be — and the card comes back to Review, to be looked at again.\n' \
      "$target" "$ticket" "$target" "$target"
    if [ -s "$detail" ]; then
      printf '\n```\n'
      sed 's/\x1b\[[0-9;]*m//g' "$detail" | sed -n '1,20p'
      printf '```\n'
    fi
    [ -z "$more" ] || printf '\n%s\n' "$more"
    [ -z "$back" ] || printf '\n%s\n' "$back"
  } >"$note"
  (AIF_BOARD_BY="aif land" aif_board_comment "$root" "$ticket" "$note" >/dev/null) || true
  if (aif_board_move "$root" "$ticket" ready top >/dev/null); then
    _aif_land_say "board" "$ticket → ready (top), for the worker to bring it onto $target"
  else
    aif_warn "could not move $ticket to Ready — run: aif board move $ticket ready --top"
  fi
  rm -f "${note:?}" "${detail:?}"
  [ -z "$AIF_LAND_OUT" ] || rm -f "$AIF_LAND_OUT"
  aif_err "$headline"
  [ -z "$more" ] || printf '%s\n' "$more" | sed '/./s/^/  /' >&2
  [ -z "$back" ] || aif_warn "$back"
  printf '  not landed — the worker brings it onto %s, and it comes back to Review: aif work %s (aif work --loop takes it from Ready by itself)\n' \
    "$target" "$ticket" >&2
  exit 1
}

# _aif_land_refused <line>… — a refusal found once the worktree was touched:
# put back, each line said as an error, the card left in Review, exit 1.
_aif_land_refused() {
  local l ticket="$AIF_LAND_CARD" back
  _aif_land_unwind
  aif_trap_disarm
  [ -z "$AIF_LAND_OUT" ] || rm -f "$AIF_LAND_OUT" "$AIF_LAND_OUT".*
  for l in "$@"; do
    aif_err "$l"
  done
  back="$(_aif_land_back_line "$ticket")"
  [ -z "$back" ] || aif_warn "$back"
  exit 1
}

# _aif_land_prepare <dir> <prepare> <log> — the project's install, in <dir>,
# rc its own. stdin closed, as the worker closes it: the output goes to a file,
# so a prompt would wait for an answer nobody can see.
_aif_land_prepare() {
  local rc=0
  (cd "$1" && eval "$2") </dev/null >"$3" 2>&1 || rc=$?
  return "$rc"
}

# _aif_land_both <list> — the lines of stdin that are also lines of <list>,
# once each: paths, matched whole (a path is not a pattern). Through the
# environment, not `-v`: a multi-line `-v` dies with "newline in string".
_aif_land_both() {
  AIF_LAND_LIST="$1" awk '
    BEGIN { n = split(ENVIRON["AIF_LAND_LIST"], l, "\n"); for (i = 1; i <= n; i++) if (l[i] != "") w[l[i]] = 1 }
    ($0 in w) && !seen[$0]++'
}

# _aif_land_dirty <root> — the tracked files of the checkout with changes, staged
# or not, one path per line. The land no longer refuses on these as such: only
# on the ones it changes (docs/DEFECTS.md 13.5).
_aif_land_dirty() {
  git -C "$1" -c core.quotePath=false diff --name-only HEAD 2>/dev/null || true
}

# _aif_land_clear <root> <from> <to> <ticket> <again> — what git does not track
# here and the fast-forward to <to> would write over (docs/DEFECTS.md 13.3):
# the paths <to> adds over <from>. Asked twice: against the branch before
# anything is touched, and against the land's merge once it exists.
#
# git refuses to write over an untracked file, byte-identical or not, and the
# commonest one is the analyst's: /aif-ba writes tasks/<ID>/ in this checkout
# and nothing commits it, so the ticket's record arriving from its branch
# stopped on the ticket's own scaffold — and the land reported that as a
# conflict for a human. The ticket's own files are listed in AIF_LAND_OWN, for
# _aif_land_aside to take aside just before the fast-forward. Any other file is
# the developer's: the land is refused, said here, rc 1.
_aif_land_clear() {
  local root="$1" from="$2" to="$3" ticket="$4" again="$5" p added untracked own="" theirs=""
  AIF_LAND_OWN=""
  added="$(git -C "$root" -c core.quotePath=false diff --name-only --diff-filter=A "$from" "$to" 2>/dev/null)" || added=""
  untracked="$(git -C "$root" -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null)" || untracked=""
  [ -n "$added" ] && [ -n "$untracked" ] || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # Matched as a whole line of the held list: `| grep -q` under pipefail
    # reads "not found" when grep leaves early (docs/DEFECTS.md 5.3).
    case "
$untracked
" in
      *"
$p
"*) ;;
      *) continue ;;
    esac
    if [ "$(aif_integrate_owner "$p" "$ticket")" = "ticket" ]; then
      own="$own$p
"
    else
      theirs="$theirs$p
"
    fi
  done <<EOF
$added
EOF
  if [ -n "$theirs" ]; then
    aif_err "untracked files here would be overwritten by the land — they are not the ticket's, so nothing was touched:"
    printf '%s' "$theirs" | sed '/^$/d; s/^/  - /' >&2
    case "$theirs" in
      .aif/* | .claude/*) aif_err "they are the set's: aif init wrote them here and they are not committed yet — commit them, then: $again" ;;
    esac
    aif_err "move them or commit them, then: $again"
    return 1
  fi
  AIF_LAND_OWN="$own"
}

# _aif_land_dirty_refusal <paths> <again> — the refusal for uncommitted changes
# to files the land changes, in the words both of its checks use.
_aif_land_dirty_refusal() {
  aif_err "uncommitted changes to files this land changes — nothing was touched:"
  printf '%s\n' "$1" | sed '/^$/d; s/^/  - /' >&2
  aif_err "commit or stash them, then: $2"
}

# _aif_land_aside <root> <branch> <ticket> — AIF_LAND_OWN taken aside, under
# .aif/tmp/ where git does not look, just before the fast-forward; they come
# back if it does not happen (_aif_land_restore_aside). The marker names them,
# so a land killed in between leaves them findable by the next one.
_aif_land_aside() {
  local root="$1" branch="$2" ticket="$3" p stamp
  AIF_LAND_ASIDE=""
  AIF_LAND_ASIDE_DIR=""
  AIF_LAND_ASIDE_DIFF=0
  [ -n "$AIF_LAND_OWN" ] || return 0
  stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  AIF_LAND_ASIDE_DIR="$root/.aif/tmp/land-$ticket-$stamp"
  if [ -n "$AIF_LAND_MARKER" ]; then
    # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
    aif_land_marker_set "$AIF_LAND_MARKER" '.aside_dir = $d | .aside = ($a | split("\n") | map(select(length > 0)))' \
      --arg d "${AIF_LAND_ASIDE_DIR#"$root"/}" --arg a "$AIF_LAND_OWN" || true
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ "$(git -C "$root" hash-object -- "$root/$p" 2>/dev/null)" != \
      "$(git -C "$root" rev-parse -q --verify "$branch:$p" 2>/dev/null)" ] &&
      ! jq -e '(.entries // [1]) | length == 0' "$root/$p" >/dev/null 2>&1; then
      AIF_LAND_ASIDE_DIFF=$((AIF_LAND_ASIDE_DIFF + 1))
    fi
    { mkdir -p "$AIF_LAND_ASIDE_DIR/$(dirname "$p")" && mv "$root/$p" "$AIF_LAND_ASIDE_DIR/$p"; } 2>/dev/null ||
      aif_die "could not take $p aside to ${AIF_LAND_ASIDE_DIR#"$root"/}"
    AIF_LAND_ASIDE="$AIF_LAND_ASIDE$p
"
  done <<EOF
$AIF_LAND_OWN
EOF
  _aif_land_say "aside" "$(printf '%s' "$AIF_LAND_ASIDE" | grep -c .) uncommitted file(s) of $ticket's own record → ${AIF_LAND_ASIDE_DIR#"$root"/}; the branch carries the record"
}

# _aif_land_restore_aside — what _aif_land_aside took aside, back where it was,
# untracked again, when the fast-forward did not happen.
_aif_land_restore_aside() {
  local p
  [ -n "$AIF_LAND_ASIDE" ] && [ -n "$AIF_LAND_ASIDE_DIR" ] || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    mkdir -p "$AIF_LAND_ROOT/$(dirname "$p")" 2>/dev/null || true
    mv -f "$AIF_LAND_ASIDE_DIR/$p" "$AIF_LAND_ROOT/$p" 2>/dev/null || true
  done <<EOF
$AIF_LAND_ASIDE
EOF
  AIF_LAND_ASIDE=""
}

# _aif_land_settled <branch> <target> — what was settled by owner, for the
# summary and the card: "<path> (<whose copy>)", comma-separated.
_aif_land_settled() {
  local p owner tab out=""
  tab="$(printf '\t')"
  while IFS="$tab" read -r p owner; do
    [ -n "$p" ] || continue
    if [ "$owner" = "ticket" ]; then
      out="$out, $p ($1)"
    else
      out="$out, $p ($2)"
    fi
  done <<EOF
$AIF_INTEGRATE_SETTLED
EOF
  printf '%s' "${out#, }"
}

# _aif_land_hooks <wt> — rc 0 when a hook `git commit` runs is installed where
# git looks for them (core.hooksPath, or .git/hooks): what tells the hooks'
# refusal from git's own.
_aif_land_hooks() {
  local dir h
  dir="$(git -C "$1" rev-parse --git-path hooks 2>/dev/null)" || return 1
  case "$dir" in
    /*) ;;
    *) dir="$1/$dir" ;;
  esac
  for h in pre-commit prepare-commit-msg commit-msg post-commit; do
    [ -x "$dir/$h" ] && return 0
  done
  return 1
}

# _aif_land_worker_verdict <root> <branch-sha> <ticket> <merge> <project> — the
# worker's verdict, when it stands for the land's merge: prints the commit it
# judged, rc 0. rc 1 when the land has to judge for itself.
#
# The worker judges the tree it reports built — green, the suite and the
# checks bound to it, on the commit that admitted the implementation, or on
# its sync's merge of the target (lib/cmd_work.sh) — and writes that commit in
# run.json as `judged`. The land's merge is that very tree whenever the target
# moved only in the analyst's tasks/ and the product partner's requests/ since
# — the commonest land of all — and running the suite again on it was minutes
# of the developer's time spent on a question already answered. It stands when
# the merge differs from it nowhere outside those two, and this checkout's
# test command and checks are the ones it was judged by. A branch built before
# the field is judged.
_aif_land_worker_verdict() {
  local root="$1" w0="$2" ticket="$3" merge="$4" project="$5" j mine theirs
  j="$(git -C "$root" show "$w0:$AIF_TASKS_DIR/$ticket/run.json" 2>/dev/null | jq -r '.judged // empty' 2>/dev/null)" || j=""
  [ -n "$j" ] || return 1
  git -C "$root" cat-file -e "$j^{commit}" 2>/dev/null || return 1
  git -C "$root" diff --quiet "$j" "$merge" -- . ":(exclude)$AIF_TASKS_DIR" ":(exclude)$AIF_REQUESTS_DIR" 2>/dev/null || return 1
  mine="$(jq -cS '{ test, checks }' "$project" 2>/dev/null)" || return 1
  theirs="$(git -C "$root" show "$j:.aif/project.json" 2>/dev/null | jq -cS '{ test, checks }' 2>/dev/null)" || return 1
  [ -n "$mine" ] && [ "$mine" = "$theirs" ] || return 1
  printf '%s' "$j"
}

# _aif_land_judge <wt> <project> <out> <target> <branch> <target-sha> — the
# verdict on the land's merge, in the worktree where it was made: the suite,
# then — once the suite is green, as green.sh orders them — every check whose
# phase holds "green", the rest of the Definition of Done. The land used to run
# the suite alone (docs/DEFECTS.md 13.5): two tickets that merged clean and
# type-checked apart could leave `tsc` red on the target, and every ticket
# after them stopped at the plan's contract check.
#
# The checks are run the way the gates' aif_g_checks_run runs them
# (sets/claude/gates/_lib.sh): from the root, stdin from /dev/null, required
# unless `"required": false`, an optional one's failure a warning. A copy,
# because lib/ does not reach into an installed set (lib/paths.sh says why).
#
# Sets AIF_LAND_VERDICT — green, red, or norun (no report where one is named,
# from a suite that exited non-zero: it did not run there) — with AIF_LAND_WHY
# the headline of a red or a norun and <out> what it quotes. What a red is
# made of is kept apart from the judging: AIF_LAND_FAILING the failing tests'
# ids, one a line; AIF_LAND_CHECKS_RED the required checks that failed,
# `<name>\t<exit>` a line. The judging is the one block at the end.
#
# And by the rule the worker's gates judge by (docs/DEFECTS.md 13.9): a
# failure is first told apart from what is not this ticket's. A failing test
# is run once more — the whole suite, the same tree — and one that passes then
# is flaky; one that fails again is looked for on the target as the land found
# it, <target-sha>, in a copy of the worktree put back there (the worker's
# _aif_work_copy_at, its dependencies linked): red there too, it is the
# target's, red before this ticket. A required check failing there too, with
# no line new on the merge (_aif_land_new_lines), is the target's as well.
# Each is let through and named — AIF_LAND_LET, on the landing note — and the
# rest judged as ever. With the target red, a land that undid on any red sent
# the card back to a worker that lets the same red through: a loop. And a
# flaky test sent a judged land back for nothing.
_aif_land_judge() {
  local wt="$1" project="$2" out="$3" target="$4" branch="$5" pre="${6:-}"
  local test_cmd report_path junit suite_rc=0 report=0 failures=0 tab name required cmd rc first="" first_rc=0
  local reported=0 again still flaky="" before="" copy="" at_pre="" pre_say pre_rc checks_let=""
  AIF_LAND_VERDICT=""
  AIF_LAND_WHY=""
  AIF_LAND_FAILING=""
  AIF_LAND_CHECKS_RED=""
  AIF_LAND_CHECKS_RAN=0
  AIF_LAND_LET=""
  tab="$(printf '\t')"
  test_cmd="$(jq -r '.test.command // empty' "$project" 2>/dev/null)"
  report_path="$(jq -r '.test.report.path // empty' "$project" 2>/dev/null)"
  junit="$(dirname "$(aif_gate_path "$AIF_LAND_ROOT" ready)")/junit.py"
  pre_say="$target"
  [ -z "$pre" ] || pre_say="$target at ${pre:0:7}"

  # 1. the suite. Exit code first; then the report the gates read, because a
  #    runner that exits 0 with failures in the report exists (the offline
  #    harness's stub is one), and green does not trust the exit code alone
  #    either.
  [ -z "$report_path" ] || rm -f "${wt:?}/${report_path:?}"
  (cd "$wt" && eval "$test_cmd") </dev/null >"$out" 2>&1 || suite_rc=$?
  [ -z "$report_path" ] || [ ! -f "$wt/$report_path" ] || report=1
  if [ "$report" -eq 1 ] && [ -f "$junit" ] && aif_have python3; then
    AIF_LAND_FAILING="$(python3 "$junit" "$wt/$report_path" 2>/dev/null |
      jq -r '.[] | select(.status == "failure" or .status == "error") | .id' 2>/dev/null)" || AIF_LAND_FAILING=""
    reported="$(printf '%s' "$AIF_LAND_FAILING" | grep -c . || true)"
  fi

  # 1b. what is not this ticket's: once more, then the target as it was.
  if [ -n "$AIF_LAND_FAILING" ]; then
    rm -f "${wt:?}/${report_path:?}"
    (cd "$wt" && eval "$test_cmd") </dev/null >"$out.again" 2>&1 || true
    again=""
    [ ! -f "$wt/$report_path" ] ||
      again="$(python3 "$junit" "$wt/$report_path" 2>/dev/null |
        jq -r '.[] | select(.status == "failure" or .status == "error") | .id' 2>/dev/null)" || again=""
    if [ -f "$wt/$report_path" ]; then
      still="$(printf '%s\n' "$AIF_LAND_FAILING" | _aif_land_both "$again")" || still=""
      flaky="$(printf '%s\n' "$AIF_LAND_FAILING" | AIF_LAND_LIST="$still" awk '
        BEGIN { n = split(ENVIRON["AIF_LAND_LIST"], l, "\n"); for (i = 1; i <= n; i++) if (l[i] != "") w[l[i]] = 1 }
        NF && !($0 in w)')" || flaky=""
      AIF_LAND_FAILING="$still"
    fi
    if [ -n "$AIF_LAND_FAILING" ] && [ -n "$pre" ] && _aif_land_copy_at "$wt" "$pre"; then
      copy="$AIF_LAND_COPY"
      rm -f "${copy:?}/${report_path:?}"
      mkdir -p "$copy/$(dirname "$report_path")"
      (cd "$copy" && eval "$test_cmd") </dev/null >"$out.pre" 2>&1 || true
      if [ -f "$copy/$report_path" ]; then
        at_pre="$(python3 "$junit" "$copy/$report_path" 2>/dev/null |
          jq -r '.[] | select(.status == "failure" or .status == "error") | .id' 2>/dev/null)" || at_pre=""
        before="$(printf '%s\n' "$AIF_LAND_FAILING" | _aif_land_both "$at_pre")" || before=""
        AIF_LAND_FAILING="$(printf '%s\n' "$AIF_LAND_FAILING" | AIF_LAND_LIST="$before" awk '
          BEGIN { n = split(ENVIRON["AIF_LAND_LIST"], l, "\n"); for (i = 1; i <= n; i++) if (l[i] != "") w[l[i]] = 1 }
          NF && !($0 in w)')" || AIF_LAND_FAILING=""
      fi
    fi
  fi
  failures="$(printf '%s' "$AIF_LAND_FAILING" | grep -c . || true)"

  # 2. the checks bound to "green", once the suite is: there is no point
  #    type-checking code whose tests do not pass. A suite whose every failure
  #    was let through is green for this.
  if { [ "$suite_rc" -eq 0 ] || [ "${reported:-0}" -gt 0 ]; } && [ "${failures:-0}" -eq 0 ]; then
    while IFS="$tab" read -r name required; do
      [ -n "$name" ] || continue
      cmd="$(jq -r --arg n "$name" '[ .checks[]? | select(.name == $n) | .command ] | .[0] // empty' "$project")"
      [ -n "$cmd" ] || continue
      AIF_LAND_CHECKS_RAN=$((AIF_LAND_CHECKS_RAN + 1))
      _aif_land_say "check" "$name — $cmd"
      rc=0
      (cd "$wt" && eval "$cmd") </dev/null >"$out.check" 2>&1 || rc=$?
      [ "$rc" -ne 0 ] || continue
      if [ "$required" = "true" ]; then
        # On the target as it was: failing there too, with nothing new here,
        # it is the target's (docs/DEFECTS.md 13.9).
        if [ -n "$pre" ] && { [ -n "$copy" ] || { _aif_land_copy_at "$wt" "$pre" && copy="$AIF_LAND_COPY"; }; }; then
          pre_rc=0
          (cd "$copy" && eval "$cmd") </dev/null >"$out.precheck" 2>&1 || pre_rc=$?
          if [ "$pre_rc" -ne 0 ] && [ -z "$(_aif_land_new_lines "$out.check" "$wt" "$out.precheck" "$copy")" ]; then
            checks_let="$checks_let, $name"
            continue
          fi
          if [ "$pre_rc" -ne 0 ]; then
            _aif_land_new_lines "$out.check" "$wt" "$out.precheck" "$copy" >"$out.new"
            cp "$out.new" "$out.check" 2>/dev/null || true
          fi
        fi
        AIF_LAND_CHECKS_RED="$AIF_LAND_CHECKS_RED$name$tab$rc
"
        if [ -z "$first" ]; then
          first="$name"
          first_rc="$rc"
          cp "$out.check" "$out.first" 2>/dev/null || true
        fi
      else
        aif_warn "optional check \"$name\" failed (exit $rc) on the result — recorded, not blocking"
      fi
    done <<EOF
$(jq -r '.checks[]? | select((.phase // []) | index("green")) | [ .name, (if .required == false then "false" else "true" end) ] | @tsv' "$project" 2>/dev/null)
EOF
  fi
  [ -z "$copy" ] || rm -rf "${copy:?}"
  AIF_LAND_COPY=""

  # What was let through, said on the landing note and here.
  [ -z "$before" ] || AIF_LAND_LET="$AIF_LAND_LET; red on $pre_say before this ticket: $(printf '%s\n' "$before" | grep -v '^$' | paste -sd, - | sed 's/,/, /g')"
  [ -z "$flaky" ] || AIF_LAND_LET="$AIF_LAND_LET; flaky — failed once, passed on a re-run: $(printf '%s\n' "$flaky" | grep -v '^$' | paste -sd, - | sed 's/,/, /g')"
  [ -z "$checks_let" ] || AIF_LAND_LET="$AIF_LAND_LET; failing the same way on $pre_say before this ticket: check ${checks_let#, }"
  AIF_LAND_LET="${AIF_LAND_LET#; }"

  # 3. the verdict — judged here, and only here.
  if [ "$suite_rc" -ne 0 ] && [ -n "$report_path" ] && [ "$report" -eq 0 ]; then
    AIF_LAND_VERDICT=norun
    AIF_LAND_WHY="the suite could not run in ${wt#"$AIF_LAND_ROOT"/} (exit $suite_rc, and no report at $report_path) — nothing landed"
  elif [ "${failures:-0}" -gt 0 ] || { [ "$suite_rc" -ne 0 ] && [ "${reported:-0}" -eq 0 ]; }; then
    AIF_LAND_VERDICT=red
    AIF_LAND_WHY="the suite is red on $target with $branch merged (exit $suite_rc, $failures failing)"
  elif [ -n "$AIF_LAND_CHECKS_RED" ]; then
    AIF_LAND_VERDICT=red
    AIF_LAND_WHY="the check \"$first\" is red on $target with $branch merged (exit $first_rc)"
    cp "$out.first" "$out" 2>/dev/null || true
  else
    AIF_LAND_VERDICT=green
  fi
  rm -f "$out.check" "$out.first" "$out.again" "$out.pre" "$out.precheck" "$out.new"
}

# _aif_land_copy_at <wt> <sha> — a copy of the worktree as it stood at <sha>,
# in AIF_LAND_COPY (the worker's _aif_work_copy_at, dependencies linked); rc 1
# when it could not be made, said.
_aif_land_copy_at() {
  AIF_LAND_COPY=""
  local c
  c="$(mktemp -d "${TMPDIR:-/tmp}/aif-land-pre-XXXXXX")" || return 1
  c="$(cd "$c" && pwd -P)" || return 1
  if ! _aif_work_copy_at "$1" "$2" "$c"; then
    rm -rf "${c:?}"
    aif_warn "the target could not be copied to tell a failure it already had from one this ticket brings — $AIF_WORK_COPY_WHY; judged as it is"
    return 1
  fi
  AIF_LAND_COPY="$c"
}

# _aif_land_new_lines <now> <now-root> <base-out> <base-root> — the lines of
# <now> in excess of <base-out>: a multiset, positions, durations and counts
# folded, each root's spellings read as one. The gates' aif_g_new_lines
# (sets/claude/gates/_lib.sh), which lib/ cannot source: the awk is the same,
# and scripts/check-work.sh holds the two to one answer.
_aif_land_new_lines() {
  local n1="$2" n2 b1="${4:-}" b2=""
  n2="$(cd "$n1" 2>/dev/null && pwd -P)" || n2="$n1"
  if [ -n "$b1" ]; then
    b2="$(cd "$b1" 2>/dev/null && pwd -P)" || b2="$b1"
  fi
  AIF_G_N1="$n1" AIF_G_N2="$n2" AIF_G_B1="$b1" AIF_G_B2="$b2" awk -v bf="$3" '
    function repl(s, from, to,   out, i) {
      if (from == "") return s
      out = ""
      while ((i = index(s, from)) > 0) {
        out = out substr(s, 1, i - 1) to
        s = substr(s, i + length(from))
      }
      return out s
    }
    function roots(s, a, b,   t) {
      if (length(b) > length(a)) { t = a; a = b; b = t }
      return repl(repl(s, a, "<root>"), b, "<root>")
    }
    function clean(s) { sub(/\r$/, "", s); gsub(/\033\[[0-9;]*m/, "", s); return s }
    function norm(s) {
      sub(/^[ \t]*[0-9]+:[0-9]+/, "#:#", s)
      gsub(/\([0-9]+,[0-9]+\)/, "(#,#)", s)
      gsub(/:[0-9]+/, ":#", s)
      gsub(/[0-9]+(\.[0-9]+)? ?(ms|seconds|secs|sec|s)([^A-Za-z0-9]|$)/, "#", s)
      gsub(/[0-9]+ (errors|error|problems|problem|warnings|warning|files|file)/, "# n", s)
      return s
    }
    BEGIN {
      while ((getline line < bf) > 0) {
        line = clean(line)
        if (line !~ /[^ \t]/) continue
        seen[norm(roots(line, ENVIRON["AIF_G_B1"], ENVIRON["AIF_G_B2"]))]++
      }
    }
    { line = clean($0) }
    line !~ /[^ \t]/ { next }
    {
      k = norm(roots(line, ENVIRON["AIF_G_N1"], ENVIRON["AIF_G_N2"]))
      if (seen[k] > 0) seen[k]--
      else print line
    }
  ' "$1"
}

# _aif_land_section <root> <target> <pre> <merge> <marker> <out> — the one step
# that moves the developer's branch: from <pre> to the land's <merge>, by a
# fast-forward and nothing else, and `landed` in the marker once it has.
#
# Run as a background job under `set -m`, a process group of its own
# (docs/FINDINGS.md #24): the TERM a review session's Ctrl-C sends to the
# land's group, and the KILL 1.4 s after it, do not reach it, and it finishes
# whatever becomes of the land (docs/DEFECTS.md 15.1). Not by ignoring the
# signals: git cleans up its own lock on a TERM it is sent, and failed the
# fast-forward after writing every file (probed, docs/FINDINGS.md #35).
# Without the project's hooks: a post-merge `npm install` would be an install
# in the developer's checkout, which is --prepare's to ask for.
#
# Exit: 0 the branch is at <merge> · 2 it was not at <pre>, or not checked out,
# when the fast-forward was to be made · 3 git would not make it (<out> says
# why) · 4 git said it did, and the branch is elsewhere.
_aif_land_section() {
  local root="$1" target="$2" pre="$3" merge="$4" marker="$5" out="$6"
  [ "$(git -C "$root" symbolic-ref -q HEAD 2>/dev/null)" = "refs/heads/$target" ] || exit 2
  [ "$(git -C "$root" rev-parse -q --verify HEAD 2>/dev/null)" = "$pre" ] || exit 2
  aif_git_own "$root" merge -q --ff-only "$merge" >"$out" 2>&1 || exit 3
  [ "$(git -C "$root" rev-parse -q --verify HEAD 2>/dev/null)" = "$merge" ] || exit 4
  aif_land_marker_set "$marker" '.state = "landed"' || true
  exit 0
}

# _aif_land_left <marker> — what the bookkeeping has left to do, for a person:
# "the card, the release and the cleanup".
_aif_land_left() {
  local made out=""
  made=" $(aif_land_marker_get "$1" '.done | join(" ")') "
  case "$made" in
    *" note "*" done "* | *" done "*" note "*) ;;
    *) out="the card" ;;
  esac
  case "$made" in
    *" release "*) ;;
    *) out="${out:+$out, }the release" ;;
  esac
  case "$made" in
    *" cleanup "*) ;;
    *) out="${out:+$out, }the cleanup" ;;
  esac
  case "$out" in
    *", "*) printf '%s and %s' "${out%, *}" "${out##*, }" ;;
    *) printf '%s' "${out:-nothing}" ;;
  esac
}

# _aif_land_stopped <EXIT|INT|TERM|HUP> — the land stopped: Ctrl-C, a
# supervisor's TERM, the terminal closing over it, or an error on the way (an
# aif_die, a command failing under set -e). Each used to leave the merge
# commit on the developer's branch, and the handler's own undo — a reset over
# the merge — could be cut in half by the KILL that follows a review
# session's TERM (docs/DEFECTS.md 14.8, 15.1). Now, by where the land is:
#
#   ""          the lock alone — a refusal, or a stop before anything was
#               touched: the lock goes, and a refusal keeps its own words
#   merging,    the worktree back on its branch, the ticket's own files back
#   judging,    from aside, the marker and the lock gone: nothing landed, and
#   ff          the developer's branch was never moved — say so
#   section     the fast-forward runs where the signal does not reach it: the
#               signal is noted, and the land acts on it once the section
#               ends (aif_cmd_land), as one of the others
#   installing, after the fast-forward: landed. The lock goes, the marker
#   landed      stays, and the next aif land finishes what is left of the
#               bookkeeping; a --prepare install cut short is named
#
# The card stays where it was: a stop decides nothing about the ticket. Armed
# with aif_trap_arm once the lock is taken, disarmed when the land ends.
_aif_land_stopped() {
  local sig="${1:-EXIT}" why target short
  if [ "$AIF_LAND_STATE" = section ]; then
    if [ "$sig" != EXIT ]; then
      AIF_LAND_SIGNAL="$sig"
      return 0
    fi
    # An exit with the fast-forward still out: what it did decides what is
    # said. It is git's — tens of milliseconds, seconds on a huge tree
    # (docs/FINDINGS.md #35).
    while [ -n "$AIF_LAND_SECTION" ] && kill -0 "$AIF_LAND_SECTION" 2>/dev/null; do
      sleep 0.05 2>/dev/null || true
    done
    if [ "$(git -C "$AIF_LAND_ROOT" rev-parse -q --verify HEAD 2>/dev/null)" = "$AIF_LAND_MERGE" ]; then
      AIF_LAND_STATE=landed
    else
      AIF_LAND_STATE=ff
    fi
  fi
  # Once, and whole: the exit an INT ends in comes back through EXIT, and a
  # second Ctrl-C must not cut the put-back in half.
  [ "$AIF_LAND_STOPPING" -eq 0 ] || return 0
  AIF_LAND_STOPPING=1
  set +e
  trap '' INT TERM HUP
  case "$sig" in
    INT) why="interrupted" ;;
    TERM) why="terminated" ;;
    HUP) why="the terminal closed (HUP)" ;;
    *) why="stopped by the error above" ;;
  esac
  target="${AIF_LAND_TARGET:-}"
  [ -n "$target" ] || target="the branch it lands on"
  case "$AIF_LAND_STATE" in
    "")
      _aif_land_unlock
      [ "$sig" = EXIT ] || {
        printf '\n' >&2
        aif_err "$why — nothing landed"
      }
      ;;
    merging | judging | ff)
      _aif_land_unwind
      printf '\n' >&2
      aif_err "$why — nothing landed: $target was never moved"
      {
        printf '%s is still in Review, and aif/%s is untouched: a stop decides nothing.\n' \
          "$AIF_LAND_CARD" "$AIF_LAND_CARD"
        if [ "$AIF_LAND_BACK_FAILED" -eq 1 ]; then
          _aif_land_back_line "$AIF_LAND_CARD"
          printf '\n'
        elif [ "$AIF_LAND_INSTALLED" -eq 1 ]; then
          printf '%s/%s is back on aif/%s; the install the land had made there is made again by the next aif work.\n' \
            "$AIF_WORK_WORKTREES" "$AIF_LAND_CARD" "$AIF_LAND_CARD"
        fi
        printf 'To land it: %s\n' "$AIF_LAND_AGAIN"
      } | sed '/./s/^/  /' >&2
      ;;
    installing | landed)
      short="$(git -C "$AIF_LAND_ROOT" rev-parse --short "$AIF_LAND_MERGE" 2>/dev/null)" || short=""
      printf '\n' >&2
      if [ "$AIF_LAND_STATE" = installing ]; then
        aif_err "$why — landed at ${short:-$AIF_LAND_MERGE}; the install here was stopped — what is installed may be partial: $AIF_LAND_PREPARE"
      fi
      aif_err "$why — after the fast-forward: $AIF_LAND_CARD is landed at ${short:-$AIF_LAND_MERGE}; $(_aif_land_left "$AIF_LAND_MARKER") left: aif land $AIF_LAND_CARD"
      _aif_land_unlock
      ;;
  esac
  [ -z "$AIF_LAND_OUT" ] || rm -f "$AIF_LAND_OUT" "$AIF_LAND_OUT".* 2>/dev/null || true
  case "$sig" in
    INT) exit 130 ;;
    TERM) exit 143 ;;
    HUP) exit 129 ;;
  esac
}

# _aif_land_column <root> <ticket> [<sha-file>] — the card's column, or empty
# when there is no card; rc 3, the reason said, when the board could not
# answer. On Trello <sha-file>, when named, gets the hash of the card's text
# as the pull writes it, from the same read (aif_board_card_column's
# AIF_BOARD_CARD_SHA_TO): what the land holds the build against
# (docs/DEFECTS.md 15.12).
#
# The column alone, never through `show`: a comments read that failed for
# good — three 500s on the actions call — makes `show` die (docs/DEFECTS.md
# 14.7), and this read of it, under `2>/dev/null … || true`, answered an
# empty column, which the case below refused as "no card on the board" —
# the wrong reason, with nothing landed. A board that cannot say where the
# card is is the environment, the 3 every other unreachable board here ends
# in, not a verdict on the ticket.
_aif_land_column() {
  local col rc=0
  col="$(AIF_BOARD_CARD_SHA_TO="${3:-}" aif_board_card_column "$1" "$2" 2>&1)" || rc=$?
  case "$rc" in
    0) printf '%s\n' "$col" ;;
    1) ;;
    *)
      aif_err "the board could not say where $2's card is — ${col:-no answer}; nothing landed (aif board check)"
      return 3
      ;;
  esac
}

# _aif_land_release <root> <ticket> — the tickets that were waiting on this
# one. Prints the ids it moved, space-separated.
#
# A dependency is a fact about a ticket, so it lives in the ticket
# (`depends_on` in aif:meta, written by the analyst for a slice that needs the
# one before it) and the board is consulted only for where things are. A
# waiting ticket moves when EVERY ticket it names is Done, not when this one
# is: a slice that needs two others stays put until the second lands.
_aif_land_release() {
  local root="$1" ticket="$2" statuses f t deps d col all_done note moved=""
  statuses="$(aif_board_status_json "$root" 2>/dev/null)" || statuses="[]"
  [ -n "$statuses" ] || statuses="[]"
  for f in "$root/$AIF_TASKS_DIR"/*/ticket.md; do
    [ -f "$f" ] || continue
    t="$(basename "$(dirname "$f")")"
    [ "$t" != "$ticket" ] || continue
    deps="$(aif_meta_json "$f" 2>/dev/null | jq -r '(.depends_on // [])[]' 2>/dev/null)" || deps=""
    [ -n "$deps" ] || continue
    printf '%s\n' "$deps" | grep -qx -- "$ticket" || continue
    col="$(printf '%s' "$statuses" | jq -r --arg t "$t" '[ .[] | select(.ticket == $t) ] | .[0].column // empty')"
    [ "$col" = "backlog" ] || continue
    all_done=1
    for d in $deps; do
      [ "$d" != "$ticket" ] || continue
      col="$(printf '%s' "$statuses" | jq -r --arg t "$d" '[ .[] | select(.ticket == $t) ] | .[0].column // empty')"
      [ "$col" = "done" ] || {
        all_done=0
        break
      }
    done
    [ "$all_done" -eq 1 ] || continue
    note="$(mktemp "${TMPDIR:-/tmp}/aif-land-XXXXXX")"
    printf 'released by aif land %s: every ticket it depends on is Done\n' "$ticket" >"$note"
    (AIF_BOARD_BY="aif land" aif_board_comment "$root" "$t" "$note" >/dev/null) || true
    rm -f "${note:?}"
    if (aif_board_move "$root" "$t" ready >/dev/null); then
      moved="$moved $t"
    else
      aif_warn "could not move $t to Ready — run: aif board move $t ready"
    fi
  done
  printf '%s' "${moved# }"
}

# _aif_land_book <root> <marker> — the bookkeeping of a land whose
# fast-forward is made, from the marker alone, each step once: the note on
# the card, Done, the release of what waited on it, the worktree and the
# branch. Each step goes into the marker's `done` as it is made, so a land
# stopped half way — a Ctrl-C, a KILL — is finished by the next aif land
# without a step made twice (docs/DEFECTS.md 15.1). AIF_LAND_RELEASED and
# AIF_LAND_CLEANUP say what it did, for the summary.
_aif_land_book() {
  local root="$1" m="$2" ticket target merge keep rel wt branch made note short wt_note br_note bullets
  local dep dep_tail installed
  ticket="$(aif_land_marker_get "$m" .ticket)"
  target="$(aif_land_marker_get "$m" .target)"
  merge="$(aif_land_marker_get "$m" .merge)"
  keep="$(aif_land_marker_get "$m" .keep)"
  rel="$(aif_land_marker_get "$m" .worktree)"
  [ -n "$rel" ] || rel="$AIF_WORK_WORKTREES/$ticket"
  installed=0
  [ "$(aif_land_marker_get "$m" .installed_in_worktree)" != true ] || installed=1
  wt="$root/$rel"
  branch="aif/$ticket"
  short="$(git -C "$root" rev-parse --short "$merge" 2>/dev/null)" || short="$merge"
  AIF_LAND_RELEASED="$(aif_land_marker_get "$m" .released)"
  AIF_LAND_CLEANUP=""
  if [ "$keep" = true ]; then
    wt_note="kept at $rel"
    br_note="kept"
  else
    wt_note="removed $rel"
    [ -e "$wt" ] || wt_note="none"
    br_note="deleted"
  fi
  made=" $(aif_land_marker_get "$m" '.done | join(" ")') "

  case "$made" in
    *" note "*) ;;
    *)
      bullets="$(aif_land_marker_get "$m" .note)"
      [ -n "$bullets" ] ||
        bullets="- merged \`$branch\` into \`$target\` at \`$short\` — the land that made it stopped after its fast-forward, and a later aif land finished it"
      dep="$(aif_land_marker_get "$m" .deps_line)"
      dep_tail="$(aif_land_marker_get "$m" .deps_tail)"
      note="$(mktemp "${TMPDIR:-/tmp}/aif-land-XXXXXX")"
      {
        printf '# %s — landed\n\n' "$ticket"
        printf '%s\n' "$bullets"
        if [ -n "$dep" ]; then
          printf -- '- dependencies: %s\n' "$dep"
          # shellcheck disable=SC2016  # the backticks are markdown on the card, not substitution
          [ -z "$dep_tail" ] || printf '\n```\n%s\n```\n\n' "$dep_tail"
        fi
        printf -- '- worktree %s; branch %s\n' "$wt_note" "$br_note"
      } >"$note"
      (AIF_BOARD_BY="aif land" aif_board_comment "$root" "$ticket" "$note" >/dev/null) ||
        aif_warn "could not post the landing note to the card — run: aif board comment $ticket <file>"
      rm -f "${note:?}"
      aif_land_marker_set "$m" '.done += ["note"]' || true
      ;;
  esac
  case "$made" in
    *" done "*) ;;
    *)
      (aif_board_move "$root" "$ticket" "done" >/dev/null) ||
        aif_warn "could not move $ticket to Done on the board — run: aif board move $ticket done"
      aif_land_marker_set "$m" '.done += ["done"]' || true
      ;;
  esac
  case "$made" in
    *" release "*) ;;
    *)
      AIF_LAND_RELEASED="$(_aif_land_release "$root" "$ticket")"
      # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
      aif_land_marker_set "$m" '.done += ["release"] | .released = $r' --arg r "$AIF_LAND_RELEASED" || true
      ;;
  esac
  case "$made" in
    *" cleanup "*) ;;
    *)
      if [ "$keep" = true ]; then
        aif_land_worktree_back "$wt" "$branch" "$installed" ||
          aif_warn "could not put $rel back on $branch — aif work $ticket puts it back"
      else
        if [ -e "$wt" ]; then
          aif_git_own "$root" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "${wt:?}"
          aif_git_own "$root" worktree prune >/dev/null 2>&1 || true
        fi
        if git -C "$root" show-ref --verify --quiet "refs/heads/$branch" &&
          ! aif_git_own "$root" branch -d "$branch" >/dev/null 2>&1; then
          br_note="kept"
          aif_warn "could not delete $branch — it is merged; remove it by hand: git branch -D $branch"
        fi
      fi
      aif_land_marker_set "$m" '.done += ["cleanup"]' || true
      ;;
  esac
  AIF_LAND_CLEANUP="worktree $wt_note; branch $branch $br_note"
}

# _aif_land_finish <root> <marker> — a land gone after its fast-forward: the
# branch is landed, and what it left of the bookkeeping is made now. Sets
# AIF_LAND_SETTLED_ID.
_aif_land_finish() {
  local root="$1" m="$2" id pid prep card="$AIF_LAND_CARD"
  id="$(aif_land_marker_get "$m" .ticket)"
  pid="$(aif_land_marker_get "$m" .pid)"
  _aif_land_say "finish" "finishing the land of $id that stopped after its fast-forward (pid ${pid:-?})"
  # A stop meanwhile is a stop after a fast-forward, the one this marker
  # names: said as such, the marker kept for the next land.
  AIF_LAND_CARD="$id"
  AIF_LAND_MARKER="$m"
  AIF_LAND_MERGE="$(aif_land_marker_get "$m" .merge)"
  AIF_LAND_STATE=landed
  _aif_land_book "$root" "$m"
  AIF_LAND_STATE=""
  AIF_LAND_MARKER=""
  AIF_LAND_MERGE=""
  AIF_LAND_CARD="$card"
  prep="$(aif_land_marker_get "$m" .prepare_here)"
  case " $(aif_land_marker_get "$m" '.done | join(" ")') " in
    *" install "*) ;;
    *)
      [ -z "$prep" ] ||
        aif_warn "$id's land was asked to install here too (--prepare), and the install may not have run, or finished: $prep"
      ;;
  esac
  rm -f "$m"
  _aif_land_say "landed" "$id is in Done; released: ${AIF_LAND_RELEASED:-nothing}; $AIF_LAND_CLEANUP"
  AIF_LAND_SETTLED_ID="$id"
}

# _aif_land_settle_ff <root> <marker> — a land gone in its fast-forward: what
# git wrote of it, read off the checkout, decides between finishing it and
# putting the target back where the land found it (docs/DEFECTS.md 15.1). Only
# a KILL of the section itself leaves this — a kill -9 on its pid, the power
# going — inside a window of milliseconds; every other stop is put back by
# the land's own handler.
#
#   the branch at the merge, or past it      landed: finished
#   git's index.lock still there             exit 3, naming it: whether a git
#                                            runs here is the person's to know
#   the index and the files the merge's      git wrote all but the ref: the
#                                            ref moved (update-ref), finished
#   the index the target's, files the        put back to the target's, the
#   target's or the merge's                  ticket's files back from aside
#   anything else on those paths             refused, naming them, exit 1
#   the branch elsewhere                     nothing of it landed: put back
_aif_land_settle_ff() {
  local root="$1" m="$2" id pid target pre merge head on lockf p tb mb ib fb all_m=1 all_t=1 bad="" back="" d a ad from
  id="$(aif_land_marker_get "$m" .ticket)"
  pid="$(aif_land_marker_get "$m" .pid)"
  target="$(aif_land_marker_get "$m" .target)"
  pre="$(aif_land_marker_get "$m" .pre)"
  merge="$(aif_land_marker_get "$m" .merge)"
  head="$(git -C "$root" rev-parse -q --verify HEAD 2>/dev/null)" || head=""
  on="$(git -C "$root" symbolic-ref -q HEAD 2>/dev/null)" || on=""
  if [ -n "$merge" ] && [ -n "$head" ] && git -C "$root" merge-base --is-ancestor "$merge" "$head" 2>/dev/null; then
    aif_land_marker_set "$m" '.state = "landed"' || true
    _aif_land_finish "$root" "$m"
    return 0
  fi
  if [ -n "$pre" ] && [ "$head" = "$pre" ] && [ "$on" = "refs/heads/$target" ] && [ -n "$merge" ]; then
    lockf="$(git -C "$root" rev-parse --git-path index.lock 2>/dev/null)" || lockf=".git/index.lock"
    case "$lockf" in
      /*) ;;
      *) lockf="$root/$lockf" ;;
    esac
    if [ -e "$lockf" ]; then
      aif_err "the land of $id (pid ${pid:-?}) died in its fast-forward and git's lock is still here — when no git command runs in this checkout: rm ${lockf#"$root"/}, then aif land $id"
      _aif_land_unlock
      aif_trap_disarm
      exit 3
    fi
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      tb="$(git -C "$root" rev-parse -q --verify "$pre:$p" 2>/dev/null)" || tb=""
      mb="$(git -C "$root" rev-parse -q --verify "$merge:$p" 2>/dev/null)" || mb=""
      ib="$(git -C "$root" ls-files -s -- "$p" 2>/dev/null | awk '$3 == 0 { print $2; exit }')" || ib=""
      fb=""
      [ ! -e "$root/$p" ] || fb="$(git -C "$root" hash-object -- "$root/$p" 2>/dev/null)" || fb="?"
      [ "$ib" = "$mb" ] || all_m=0
      [ "$ib" = "$tb" ] || all_t=0
      if [ "$fb" != "$mb" ]; then
        all_m=0
        [ "$fb" = "$tb" ] || bad="$bad$p
"
      elif [ "$fb" != "$tb" ]; then
        back="$back$p
"
      fi
    done <<EOF
$(git -C "$root" -c core.quotePath=false diff --name-only "$pre" "$merge" 2>/dev/null)
EOF
    if [ "$all_m" -eq 1 ] && aif_git_own "$root" update-ref "refs/heads/$target" "$merge" "$pre" >/dev/null 2>&1; then
      _aif_land_say "settle" "the land of $id (pid ${pid:-?}) died in its fast-forward after git wrote it all but the branch's ref — the ref moved to it"
      aif_land_marker_set "$m" '.state = "landed"' || true
      _aif_land_finish "$root" "$m"
      return 0
    fi
    if [ "$all_t" -ne 1 ] || [ -n "$bad" ]; then
      aif_err "the land of $id (pid ${pid:-?}) died in its fast-forward, and what is here is neither $target as it found it nor its merge — nothing was touched; look at these, then aif land $id:"
      printf '%s' "$bad" | sed '/^$/d; s/^/  - /' >&2
      _aif_land_unlock
      aif_trap_disarm
      exit 1
    fi
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if [ -n "$(git -C "$root" rev-parse -q --verify "$pre:$p" 2>/dev/null)" ]; then
        aif_git_own "$root" checkout "$pre" -- "$p" >/dev/null 2>&1 || true
      else
        rm -f "${root:?}/$p"
      fi
    done <<EOF
$back
EOF
  fi
  # Put back: the ticket's own files from aside, where nothing took their
  # place, and the worktree on its branch.
  ad="$(aif_land_marker_get "$m" .aside_dir)"
  a=""
  if [ -n "$ad" ] && [ -d "$root/$ad" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      [ -f "$root/$ad/$p" ] || continue
      if [ -e "$root/$p" ]; then
        aif_warn "$p is here again — the copy the land took aside stays in $ad"
        continue
      fi
      mkdir -p "$(dirname "$root/$p")" 2>/dev/null || true
      mv "$root/$ad/$p" "$root/$p" 2>/dev/null && a="$a, $p"
    done <<EOF
$(jq -r '(.aside // [])[]' "$m" 2>/dev/null)
EOF
  fi
  d="$(aif_land_marker_get "$m" .worktree)"
  [ -n "$d" ] || d="$AIF_WORK_WORKTREES/$id"
  _aif_land_wt_settle "$root" "$m" "$id" "$d"
  # Said apart, not as a ${a:+…} default: bash 3.2 reads an apostrophe there
  # as a quote that opens.
  from=""
  [ -z "$a" ] || from="; the ticket's own files are back from $ad: ${a#, }"
  if [ "$head" = "$pre" ]; then
    _aif_land_say "settle" "an earlier land of $id (pid ${pid:-?}) stopped in its fast-forward — $target is back at $(git -C "$root" rev-parse --short "$pre" 2>/dev/null), as it was$from"
  else
    _aif_land_say "settle" "an earlier land of $id (pid ${pid:-?}) stopped before its fast-forward moved $target — $target has moved since, and nothing of that land is in it$from"
  fi
  rm -f "$m"
}

# _aif_land_wt_settle <root> <marker> <ticket> <worktree-rel> — the worktree a
# gone land borrowed, back on its branch: unless a live worker is on that
# ticket, which puts it back itself (lib/cmd_work.sh _aif_work_worktree), or
# it is on a branch already.
_aif_land_wt_settle() {
  local root="$1" m="$2" id="$3" rel="$4" wt installed=0
  wt="$root/$rel"
  [ -e "$wt/.git" ] || return 0
  ! _aif_work_lock_live "$(aif_run_lock_dir "$root" "$id")" || return 0
  git -C "$wt" symbolic-ref -q HEAD >/dev/null 2>&1 && return 0
  [ "$(aif_land_marker_get "$m" .installed_in_worktree)" != true ] || installed=1
  aif_land_worktree_back "$wt" "aif/$id" "$installed" ||
    aif_warn "$rel could not be put back on aif/$id — aif work $id puts it back"
}

# _aif_land_settle_dead <root> — a marker left by a land that is gone, settled
# before this land does anything of its own (docs/DEFECTS.md 15.1). Called
# holding the lock: the land that wrote it holds nothing any more. Its
# fast-forward may outlive it — it runs out of reach of what stopped the land
# — and is waited for first. Sets AIF_LAND_SETTLED_ID to the ticket whose
# land it finished.
_aif_land_settle_dead() {
  local root="$1" m state id pid sec w=0 d
  m="$(aif_land_marker_file "$root")"
  AIF_LAND_SETTLED_ID=""
  [ -f "$m" ] || return 0
  if ! jq -e 'type == "object" and (.ticket | type == "string")' "$m" >/dev/null 2>&1; then
    mv -f "$m" "$m.unreadable" 2>/dev/null || rm -f "$m"
    aif_warn "a land's marker here could not be read — set aside as ${m#"$root"/}.unreadable"
    return 0
  fi
  id="$(aif_land_marker_get "$m" .ticket)"
  pid="$(aif_land_marker_get "$m" .pid)"
  sec="$(cat "${m%.json}.section" 2>/dev/null)" || sec=""
  while aif_land_pid_live "$sec" && [ "$w" -lt 600 ]; do
    [ "$w" -gt 0 ] || _aif_land_say "settle" "the fast-forward of an earlier land of $id still runs (pid $sec) — waiting for it"
    sleep 0.1 2>/dev/null || true
    w=$((w + 1))
  done
  rm -f "${m%.json}.section"
  state="$(aif_land_marker_get "$m" .state)"
  case "$state" in
    landed) _aif_land_finish "$root" "$m" ;;
    ff) _aif_land_settle_ff "$root" "$m" ;;
    *)
      d="$(aif_land_marker_get "$m" .worktree)"
      [ -n "$d" ] || d="$AIF_WORK_WORKTREES/$id"
      _aif_land_wt_settle "$root" "$m" "$id" "$d"
      _aif_land_say "settle" "an earlier land of $id (pid ${pid:-?}) stopped before it moved $(aif_land_marker_get "$m" .target) — nothing landed; $d is back on aif/$id"
      rm -f "$m"
      ;;
  esac
}

aif_cmd_land() {
  local ticket="" run_suite=1 keep=0 run_prepare=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-suite) run_suite=0 ;;
      --keep) keep=1 ;;
      --prepare) run_prepare=1 ;;
      -h | --help)
        _aif_land_usage
        return 0
        ;;
      -*) aif_die "unknown option: $1" ;;
      *) ticket="$1" ;;
    esac
    shift
  done
  [ -n "$ticket" ] || aif_die "usage: aif land <ticket> [--no-suite] [--keep] [--prepare]"

  # This land again: as a stop gives it, from Review, and as a failure note
  # gives it — the card will be in Needs Human, and land refuses a card that is
  # not in Review.
  local rerun="aif land $ticket"
  [ "$run_suite" -eq 1 ] || rerun="$rerun --no-suite"
  [ "$keep" -eq 0 ] || rerun="$rerun --keep"
  [ "$run_prepare" -eq 0 ] || rerun="$rerun --prepare"
  local again="aif board move $ticket review && $rerun"

  local root main
  root="$(aif_require_project)"
  main="$(aif_main_root "$root")"
  if [ "$root" != "$main" ]; then
    aif_err "this is a worker's checkout, not the main one — land from: cd $main"
    exit 3
  fi

  local pattern
  pattern="$(aif_board_ticket_re "$root")"
  printf '%s' "$ticket" | grep -qE "$pattern" ||
    aif_die "ticket '$ticket' does not match $pattern (from project.json)"

  # One land per checkout, from here to its end (aif_land_lock_dir): one moves
  # the branch another is judging a merge onto, and the worktree a land
  # borrows is the land's while it holds this. A lock whose land is gone is
  # taken over, and what it left settled before anything else.
  local lock
  lock="$(aif_land_lock_dir "$root")"
  if ! _aif_work_lock_take "$lock" '*aif\ land*'; then
    # shellcheck disable=SC2153  # set by _aif_work_lock_take (lib/cmd_work.sh)
    aif_err "another aif land runs in this checkout ($AIF_LOCK_HELD) — one at a time, and nothing was touched. When it is done: $rerun"
    exit 3
  fi
  jq -n --argjson pid "$$" --arg t "$ticket" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{ ticket: $t, pid: $pid, started_at: $at }' >"$lock/owner.json.tmp" 2>/dev/null &&
    mv "$lock/owner.json.tmp" "$lock/owner.json"
  AIF_LAND_LOCK="$lock"
  AIF_LAND_ROOT="$root"
  AIF_LAND_CARD="$ticket"
  AIF_LAND_AGAIN="$rerun"
  aif_trap_arm "_aif_land_stopped"
  [ -z "$AIF_LOCK_DEAD" ] ||
    _aif_land_say "lock" "the land that held this checkout (pid $AIF_LOCK_DEAD) is gone — taken over"
  _aif_land_settle_dead "$root"
  if [ "$AIF_LAND_SETTLED_ID" = "$ticket" ]; then
    _aif_land_unlock
    aif_trap_disarm
    printf '%s is already in Done — its land had stopped after the fast-forward, and is finished now\n' "$ticket"
    return 0
  fi

  # The install --prepare runs, from this checkout's config as it stands — the
  # developer's own instruction, which is where the worker reads it too.
  local prepare
  prepare="$(jq -r '.prepare // empty' "$(aif_project_config "$root")" 2>/dev/null)" || prepare=""
  [ "$run_prepare" -eq 0 ] || [ -n "$prepare" ] ||
    aif_die "--prepare: .aif/project.json names no \"prepare\" — set it to the project's install (e.g. \"npm ci\")"

  local branch="aif/$ticket"
  git -C "$root" show-ref --verify --quiet "refs/heads/$branch" ||
    aif_die "no branch $branch — nothing was built for $ticket (aif work $ticket)"

  # The board is the authority on whether a yes is allowed: a card in Review is
  # a build waiting for exactly this.
  if ! aif_board_check "$root" >/dev/null 2>&1; then
    aif_board_check "$root" >&2 || true
    aif_err "the board is not reachable as configured — fix that first (aif board check)"
    exit 3
  fi
  local column shaf card_sha=""
  shaf="$(mktemp "${TMPDIR:-/tmp}/aif-land-card-XXXXXX")" || shaf=""
  column="$(_aif_land_column "$root" "$ticket" "$shaf")" || {
    [ -z "$shaf" ] || rm -f "$shaf"
    exit 3
  }
  if [ -n "$shaf" ]; then
    card_sha="$(sed -n 1p "$shaf" 2>/dev/null)" || card_sha=""
    rm -f "$shaf"
  fi
  case "$column" in
    review) ;;
    done)
      printf '%s is already in Done — nothing to land\n' "$ticket"
      _aif_land_unlock
      aif_trap_disarm
      return 0
      ;;
    "") aif_die "$ticket has no card on the board" ;;
    *) aif_die "$ticket is in $column, not Review — landing is the yes after a review. When it has been reviewed: aif board move $ticket review" ;;
  esac

  # The run record travels on the branch. A card in Review whose run did not
  # end `built` is a card somebody moved by hand.
  local runrec status built_sha
  runrec="$(git -C "$root" show "$branch:$AIF_TASKS_DIR/$ticket/run.json" 2>/dev/null)" || runrec=""
  status="$(printf '%s' "$runrec" | jq -r '.status // empty' 2>/dev/null)" || status=""
  [ "$status" = "built" ] ||
    aif_die "the run on $branch did not end built (status: ${status:-no run record}) — nothing to land"

  # On Trello the card is the ticket, and a person may edit it in the browser
  # after its build — after the review's demo, even: the land merged the build
  # of the text before, the criterion added since in no test, and the card
  # went to Done as if it had been built (docs/DEFECTS.md 15.12). The card as
  # it is now — read above for its column, hashed as the pull writes it, no
  # request more — is held against the ticket the run built (its
  # ticket_sha256), as the shift holds it before it offers the land: another
  # text is refused, nothing touched, the card left in Review. A record with
  # no hash says nothing, and the land goes on as before.
  built_sha="$(printf '%s' "$runrec" | jq -r '.ticket_sha256 // empty | strings' 2>/dev/null)" || built_sha=""
  if [ -n "$card_sha" ] && [ -n "$built_sha" ] && [ "$card_sha" != "$built_sha" ]; then
    aif_die "$ticket's card changed after its build — $branch is a build of the card's earlier text, and a land would merge that. Nothing was touched, and the card stays in Review; build it from the card as it is now: aif work $ticket"
  fi

  # A worker on the ticket owns its worktree until it ends: a card in Review
  # with a live worker is one somebody just sent back.
  local runlock
  runlock="$(aif_run_lock_dir "$root" "$ticket")"
  _aif_work_lock_live "$runlock" &&
    aif_die "a worker is on $ticket right now (pid $(_aif_work_lock_pid "$runlock")) — its worktree is the worker's until it ends, so nothing was touched. When it is done: $rerun"

  local target pre w0 inprog
  target="$(git -C "$root" symbolic-ref --short HEAD 2>/dev/null)" ||
    aif_die "HEAD is detached — check out the branch to land onto"
  pre="$(git -C "$root" rev-parse HEAD)"
  w0="$(git -C "$root" rev-parse "refs/heads/$branch")"
  for inprog in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    ! git -C "$root" rev-parse -q --verify "$inprog" >/dev/null 2>&1 ||
      aif_die "git has a $(printf '%s' "$inprog" | sed 's/_HEAD$//' | tr 'A-Z_' 'a-z-') in progress in this checkout — finish it or abort it, then: $rerun"
  done

  local title
  title="$(git -C "$root" show "$branch:$AIF_TASKS_DIR/$ticket/ticket.md" 2>/dev/null |
    sed -n 's/^# *//p' | head -1 | sed "s/^$ticket *[—:-]* *//")"
  [ -n "$title" ] || title="$ticket"
  local marker
  marker="$(aif_land_marker_file "$root")"

  printf '\n%sland%s %s → %s\n\n' "$AIF_C_BOLD" "$AIF_C_RESET" "$ticket" "$target" >&2

  # Already in: no merge and no verdict, the bookkeeping only. It used to run
  # the suite on the checkout for a merge it did not make.
  if git -C "$root" merge-base --is-ancestor "$w0" "$pre" 2>/dev/null; then
    _aif_land_say "merge" "$branch was already in $target — nothing merged, nothing judged"
    # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
    aif_land_marker_set "$marker" \
      '.ticket = $t | .pid = $pid | .started_at = $at | .target = $tg | .pre = $pre | .branch = $w0 | .merge = $pre
       | .worktree = $wt | .keep = $keep | .state = "landed" | .done = []
       | .note = ("- `" + $b + "` was already in `" + $tg + "` (at `" + ($pre[0:7]) + "`) — nothing merged, nothing judged")' \
      --arg t "$ticket" --argjson pid "$$" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg tg "$target" \
      --arg pre "$pre" --arg w0 "$w0" --arg b "$branch" --arg wt "$AIF_WORK_WORKTREES/$ticket" \
      --argjson keep "$([ "$keep" -eq 1 ] && printf true || printf false)" || true
    AIF_LAND_MARKER="$marker"
    AIF_LAND_TARGET="$target"
    AIF_LAND_MERGE="$pre"
    AIF_LAND_STATE=landed
    _aif_land_book "$root" "$marker"
    rm -f "$marker"
    AIF_LAND_MARKER=""
    _aif_land_unlock
    aif_trap_disarm
    printf '\nlanded:   %s → %s at %s — it was already there\n' "$ticket" "$target" "$(git -C "$root" rev-parse --short "$pre")"
    printf 'board:    %s is in Done  (aif board show %s)\n' "$ticket" "$ticket"
    if [ -n "$AIF_LAND_RELEASED" ]; then
      printf 'released: %s → Ready\n' "$AIF_LAND_RELEASED"
    else
      printf 'released: nothing was waiting on it\n'
    fi
    printf 'cleanup:  %s\n' "$AIF_LAND_CLEANUP"
    return 0
  fi

  # The ticket's worktree, which the land borrows: this repository's — a copied
  # project's still points at the one it was copied from, and git run there
  # writes that one (docs/FINDINGS.md #20) — on its branch, and clean.
  local wt="$root/$AIF_WORK_WORKTREES/$ticket" rel="$AIF_WORK_WORKTREES/$ticket" made_wt=0 wt_main on wt_dirty
  if [ -e "$wt/.git" ]; then
    wt_main="$(aif_main_root "$wt")"
    [ "$wt_main" = "$root" ] ||
      aif_die "$rel is a worktree of another repository ($wt_main): a copied project's worktree still points at the one it was copied from. Here: git worktree repair $rel, then: $rerun"
    on="$(git -C "$wt" symbolic-ref -q HEAD 2>/dev/null)" || on=""
    [ "$on" = "refs/heads/$branch" ] ||
      aif_die "$rel is on ${on#refs/heads/}${on:+, }${on:-a detached HEAD, }not $branch — check $branch out there (git -C $rel checkout $branch), then: $rerun"
    wt_dirty="$(git -C "$wt" -c core.quotePath=false status --porcelain --untracked-files=no 2>/dev/null)" || wt_dirty=""
    if [ -n "$wt_dirty" ]; then
      aif_err "$rel has uncommitted changes to tracked files — nothing was touched:"
      printf '%s\n' "$wt_dirty" | sed 's/^/  /' >&2
      aif_die "commit them on $branch — they land with it — or drop them, then: $rerun"
    fi
  elif [ -e "$wt" ]; then
    aif_die "$rel is there and is not a worktree — move it aside, then: $rerun"
  else
    made_wt=1
  fi

  # The checkout, against what the branch changes: an untracked file in the
  # way, and uncommitted changes to the files themselves. Everything else of
  # the developer's — their own edits, staged or not — stays as it is
  # (docs/DEFECTS.md 13.5).
  _aif_land_clear "$root" "$pre" "$w0" "$ticket" "$rerun" || exit 1
  local base dirty hit
  base="$(git -C "$root" merge-base "$pre" "$w0" 2>/dev/null)" || base="$pre"
  dirty="$(_aif_land_dirty "$root")"
  if [ -n "$dirty" ]; then
    hit="$(git -C "$root" -c core.quotePath=false diff --name-only "$base" "$w0" 2>/dev/null | _aif_land_both "$dirty")" || hit=""
    if [ -n "$hit" ]; then
      _aif_land_dirty_refusal "$hit" "$rerun"
      exit 1
    fi
  fi

  # From here the land touches the worktree, and says so in the marker first:
  # a land killed from now on is put back by the next one.
  local out n_commits
  out="$(mktemp "${TMPDIR:-/tmp}/aif-land-XXXXXX")"
  AIF_LAND_OUT="$out"
  n_commits="$(git -C "$root" rev-list --count "$pre..$w0" 2>/dev/null || printf '?')"
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  aif_land_marker_set "$marker" \
    '{ ticket: $t, pid: $pid, started_at: $at, target: $tg, pre: $pre, branch: $w0, merge: null,
       worktree: $wt, made_worktree: $made, installed_in_worktree: false, keep: $keep,
       prepare_here: (if $ph == "" then null else $ph end), aside_dir: null, aside: [],
       state: "merging", done: [] }' \
    --arg t "$ticket" --argjson pid "$$" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg tg "$target" \
    --arg pre "$pre" --arg w0 "$w0" --arg wt "$rel" \
    --argjson made "$([ "$made_wt" -eq 1 ] && printf true || printf false)" \
    --argjson keep "$([ "$keep" -eq 1 ] && printf true || printf false)" \
    --arg ph "$([ "$run_prepare" -eq 1 ] && printf '%s' "$prepare")" ||
    aif_die "could not write the land's marker, ${marker#"$root"/} — nothing was touched"
  AIF_LAND_MARKER="$marker"
  AIF_LAND_STATE=merging
  AIF_LAND_TARGET="$target"
  AIF_LAND_BRANCH="$branch"
  AIF_LAND_WT="$wt"

  # 1. the worktree at the target's tip — cut there when the land has none
  #    to borrow (aif work --clean, or built elsewhere).
  if [ "$made_wt" -eq 1 ]; then
    aif_git_own "$root" worktree prune >/dev/null 2>&1 || true
    mkdir -p "$(dirname "$wt")"
    aif_git_own "$root" worktree add -q --detach "$wt" "$pre" >"$out" 2>&1 ||
      _aif_land_fail "$root" "$ticket" "git could not cut $rel at $target for the land, in its own words below" "$out" "$again"
    _aif_land_say "worktree" "cut $rel at $target for the land"
  else
    aif_git_own "$wt" checkout -q --detach "$pre" >"$out" 2>&1 ||
      _aif_land_fail "$root" "$ticket" "git could not put $rel at $target's tip for the land, in its own words below" "$out" "$again"
  fi

  # 2. the merge, there. --no-ff even when a fast-forward is possible: the
  #    ticket stays one commit to find, revert, or bisect to.
  local settled="" left
  AIF_INTEGRATE_SETTLED=""
  AIF_INTEGRATE_LEFT=""
  if ! aif_git_own "$wt" -c merge.conflictStyle=diff3 merge -q --no-ff --no-commit "$w0" >"$out" 2>&1; then
    if ! git -C "$wt" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
      _aif_land_fail "$root" "$ticket" "$branch does not merge into $target — git refused before merging, in its own words below" "$out" "$again"
    fi
    if ! aif_integrate_own "$wt" "$ticket" theirs; then
      left="$(printf '%s' "$AIF_INTEGRATE_LEFT" | sed '/^$/d' | paste -sd ',' - | sed 's/,/, /g')"
      _aif_land_requeue "$root" "$ticket" "$branch conflicts with $target in ${left:-files git could not settle}" "$out" "$target"
    fi
  fi
  [ -z "$AIF_INTEGRATE_SETTLED" ] || settled="$(_aif_land_settled "$branch" "$target")"
  if [ -n "$settled" ]; then
    _aif_land_say "merge" "$branch onto $target — $n_commits commit(s); conflicts in aif's own files settled by owner: $settled"
  else
    _aif_land_say "merge" "$branch onto $target — $n_commits commit(s), in $rel"
  fi

  # 3. the install, there: what the merge moved against what the worktree has
  #    installed — the branch's, as the worker installed it — or everything,
  #    in a worktree the land cut. Never here: that is --prepare's, after.
  local deps_wt=""
  deps_wt="$(git -C "$wt" -c core.quotePath=false diff --cached --name-only "$w0" 2>/dev/null |
    grep -E "$AIF_DEP_MANIFESTS|$AIF_DEP_LOCKFILES" | sort -u | paste -sd ',' - | sed 's/,/, /g')" || deps_wt=""
  if [ "$run_suite" -eq 1 ] && [ -n "$prepare" ] && { [ -n "$deps_wt" ] || [ "$made_wt" -eq 1 ]; }; then
    local prep_rc=0 rewrote log="$wt/.aif/tmp/prepare.log"
    if [ -n "$deps_wt" ]; then
      _aif_land_say "prepare" "$deps_wt moved — $prepare, in $rel"
    else
      _aif_land_say "prepare" "$prepare, in $rel"
    fi
    mkdir -p "$wt/.aif/tmp"
    AIF_LAND_INSTALLED=1
    aif_land_marker_set "$marker" '.installed_in_worktree = true' || true
    _aif_land_prepare "$wt" "$prepare" "$log" || prep_rc=$?
    # An install from the lockfile leaves the tree as the merge made it. One
    # that rewrites a tracked file installed something the merge did not pin.
    rewrote="$(git -C "$wt" -c core.quotePath=false diff --name-only 2>/dev/null |
      paste -sd ',' - | sed 's/,/, /g')" || rewrote=""
    if [ "$prep_rc" -ne 0 ] || [ -n "$rewrote" ]; then
      # Install tools print the reason last.
      { grep -v '^[[:space:]]*$' "$log" | tail -20 >"$out"; } 2>/dev/null || true
      if [ "$prep_rc" -ne 0 ]; then
        _aif_land_fail "$root" "$ticket" \
          "\"prepare\" ($prepare) failed in $rel on the merge${deps_wt:+, which moved $deps_wt} (exit $prep_rc)" "$out" "$again"
      fi
      _aif_land_fail "$root" "$ticket" \
        "\"prepare\" ($prepare) rewrote $rewrote in $rel — it has to install what the lockfile pins, as it pins it (npm ci, not npm install)" "$out" "$again"
    fi
  fi

  # 4. the land's merge commit, with the project's hooks — pre-commit,
  #    prepare-commit-msg, commit-msg, post-commit — in the worktree, with its
  #    install, as the developer. Not `git merge` committing: that runs
  #    pre-merge-commit and never pre-commit (probed, docs/FINDINGS.md #35).
  #    Every commit of aif's before it skipped them (aif_git_own): this is the
  #    one they are for (docs/DEFECTS.md 13.11). What a hook left unstaged is
  #    not in the commit, and is reset away.
  local subject="aif: land $ticket — $title" crc=0 merge
  if [ -n "$settled" ]; then
    git -C "$wt" commit -q --cleanup=strip -m "$subject" -m "Settled by owner (aif's own files): $settled" >"$out" 2>&1 || crc=$?
  else
    git -C "$wt" commit -q --cleanup=strip -m "$subject" >"$out" 2>&1 || crc=$?
  fi
  if [ "$crc" -ne 0 ]; then
    if _aif_land_hooks "$wt"; then
      _aif_land_fail "$root" "$ticket" \
        "the project's git hooks refused the land's merge commit (git commit exited $crc), in their own words below — nothing landed" "$out" "$again" \
        "aif's own commits skip the hooks; if this one checks what a build should meet, bind it as a check (aif project checks)."
    fi
    _aif_land_fail "$root" "$ticket" "git refused the land's merge commit (git commit exited $crc), in its own words below — nothing landed" "$out" "$again"
  fi
  merge="$(git -C "$wt" rev-parse HEAD)"
  aif_git_own "$wt" reset -q --hard "$merge" >/dev/null 2>&1 || true
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  aif_land_marker_set "$marker" '.merge = $m | .state = "judging"' --arg m "$merge" || true
  AIF_LAND_MERGE="$merge"
  AIF_LAND_STATE=judging

  # 5. exact now that the merge exists: the target where the land found it —
  #    a hook, or a person in another terminal, may have moved it — and the
  #    checkout clear on every path the fast-forward writes.
  local now touched
  now="$(git -C "$root" rev-parse -q --verify "refs/heads/$target" 2>/dev/null)" || now=""
  if [ "$now" != "$pre" ] || [ "$(git -C "$root" symbolic-ref -q HEAD 2>/dev/null)" != "refs/heads/$target" ]; then
    _aif_land_refused "$target moved while the land ran (it was at ${pre:0:7}, it is at $(git -C "$root" rev-parse --short HEAD 2>/dev/null)) — nothing landed; $ticket is still in Review: $rerun"
  fi
  touched="$(git -C "$root" -c core.quotePath=false diff --name-only "$pre" "$merge" 2>/dev/null)" || touched=""
  dirty="$(_aif_land_dirty "$root")"
  if [ -n "$dirty" ]; then
    hit="$(printf '%s\n' "$touched" | _aif_land_both "$dirty")" || hit=""
    if [ -n "$hit" ]; then
      _aif_land_dirty_refusal "$hit" "$rerun"
      _aif_land_refused "nothing landed; $ticket is still in Review"
    fi
  fi
  _aif_land_clear "$root" "$pre" "$merge" "$ticket" "$rerun" ||
    _aif_land_refused "nothing landed; $ticket is still in Review"

  # 6. the verdict.
  local project test_cmd suite="" j
  project="$(aif_project_config "$root")"
  test_cmd="$(jq -r '.test.command // empty' "$project" 2>/dev/null)"
  if [ "$run_suite" -eq 0 ]; then
    suite="skipped (--no-suite)"
  elif [ -z "$test_cmd" ]; then
    suite="skipped — project.json names no test command"
  elif j="$(_aif_land_worker_verdict "$root" "$w0" "$ticket" "$merge" "$project")"; then
    suite="the worker's verdict stands — green, with the checks, on $(git -C "$root" rev-parse --short "$j")"
    _aif_land_say "suite" "$suite: the merge is that tree"
  else
    _aif_land_say "suite" "$test_cmd — in $rel"
    _aif_land_judge "$wt" "$project" "$out" "$target" "$branch" "$pre"
    case "$AIF_LAND_VERDICT" in
      green) ;;
      red) _aif_land_requeue "$root" "$ticket" "$AIF_LAND_WHY" "$out" "$target" ;;
      *) _aif_land_fail "$root" "$ticket" "$AIF_LAND_WHY" "$out" "$again" ;;
    esac
    suite="green ($test_cmd"
    [ "$AIF_LAND_CHECKS_RAN" -eq 0 ] || suite="$suite, and $AIF_LAND_CHECKS_RAN check(s)"
    suite="$suite) — in $rel"
    # What the verdict let through — the target's own red, a flaky test — is
    # said on the landing note, where the reviewer reads (docs/DEFECTS.md 13.9).
    [ -z "$AIF_LAND_LET" ] || suite="$suite — let through, $AIF_LAND_LET"
    if [ -n "$AIF_LAND_LET" ]; then
      _aif_land_say "suite" "green — let through, $AIF_LAND_LET"
    else
      _aif_land_say "suite" "green"
    fi
  fi

  # What the land moves that an install here would follow: said, and with
  # --prepare installed, after the fast-forward.
  local deps_here dep_line="" bullets aside=""
  deps_here="$(printf '%s\n' "$touched" | grep -E "$AIF_DEP_MANIFESTS|$AIF_DEP_LOCKFILES" | sort -u |
    paste -sd ',' - | sed 's/,/, /g')" || deps_here=""
  if [ -n "$deps_here" ] && [ "$run_prepare" -eq 0 ]; then
    dep_line="$deps_here moved — not installed in this checkout"
    [ "$run_suite" -eq 0 ] || [ -z "$test_cmd" ] || [ -z "$prepare" ] ||
      dep_line="$dep_line (they were, in $rel, for the verdict)"
    if [ -n "$prepare" ]; then
      dep_line="$dep_line. When you need them here: $prepare"
    else
      dep_line="$dep_line. When you need them here, install them from the lockfile"
    fi
  elif [ -z "$deps_here" ] && [ "$run_prepare" -eq 1 ]; then
    _aif_land_say "prepare" "not run here — no dependency manifest or lockfile moved"
  fi

  # 7. the fast-forward. The ticket's own untracked files go aside first —
  #    git writes over no untracked file — then the section moves the branch.
  bullets="- merged \`$branch\` into \`$target\` at \`${merge:0:7}\` ($n_commits commits)"
  [ -z "$settled" ] || bullets="$bullets
- conflicts in aif's own files, settled by owner: $settled"
  [ -z "$suite" ] || bullets="$bullets
- suite on the result: $suite"
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  aif_land_marker_set "$marker" '.state = "ff" | .note = $n | .deps_line = (if $d == "" then null else $d end)' \
    --arg n "$bullets" --arg d "$dep_line" || true
  AIF_LAND_STATE=ff
  _aif_land_aside "$root" "$branch" "$ticket"
  if [ -n "$AIF_LAND_ASIDE" ]; then
    aside="$(printf '%s' "$AIF_LAND_ASIDE" | grep -c .) uncommitted file(s) of the ticket's record taken aside to ${AIF_LAND_ASIDE_DIR#"$root"/}"
    if [ "$AIF_LAND_ASIDE_DIFF" -gt 0 ]; then
      aside="$aside — $AIF_LAND_ASIDE_DIFF of them differ from what landed; compare before deleting them"
    else
      aside="$aside — the same as what landed"
    fi
    bullets="$bullets
- $aside"
    # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
    aif_land_marker_set "$marker" '.note = $n' --arg n "$bullets" || true
  fi

  local secfile="${marker%.json}.section" sec_rc=0 landed=0
  AIF_LAND_SIGNAL=""
  AIF_LAND_STATE=section
  [ -z "$AIF_LAND_SIGNAL" ] || {
    AIF_LAND_STATE=ff
    _aif_land_stopped "$AIF_LAND_SIGNAL"
  }
  set -m
  _aif_land_section "$root" "$target" "$pre" "$merge" "$marker" "$out" </dev/null &
  AIF_LAND_SECTION=$!
  set +m
  printf '%s\n' "$AIF_LAND_SECTION" >"$secfile" 2>/dev/null || true
  # Polled, then waited for once: the real exit code on bash 3.2, which has no
  # wait -n (docs/FINDINGS.md #23). A signal meanwhile is only noted.
  while kill -0 "$AIF_LAND_SECTION" 2>/dev/null; do
    sleep 0.05 2>/dev/null || true
  done
  wait "$AIF_LAND_SECTION" 2>/dev/null || sec_rc=$?
  rm -f "$secfile"
  AIF_LAND_SECTION=""
  [ "$sec_rc" -eq 0 ] && [ "$(git -C "$root" rev-parse -q --verify HEAD 2>/dev/null)" = "$merge" ] && landed=1
  if [ "$landed" -eq 1 ]; then
    AIF_LAND_STATE=landed
    AIF_LAND_ASIDE=""
  else
    AIF_LAND_STATE=ff
  fi
  [ -z "$AIF_LAND_SIGNAL" ] || _aif_land_stopped "$AIF_LAND_SIGNAL"
  if [ "$landed" -eq 0 ]; then
    now="$(git -C "$root" rev-parse -q --verify HEAD 2>/dev/null)" || now=""
    if [ "$sec_rc" -eq 2 ] || [ "$now" != "$pre" ]; then
      _aif_land_refused "$target moved while the land ran (it was at ${pre:0:7}, it is at ${now:0:7}) — nothing landed; $ticket is still in Review: $rerun"
    fi
    aif_err "git would not fast-forward $target to the land's merge, in its own words:"
    sed 's/\x1b\[[0-9;]*m//g' "$out" | sed -n '1,12p' | sed 's/^/  /' >&2
    _aif_land_refused "nothing landed; $ticket is still in Review: $rerun"
  fi

  # Landed. 8. --prepare's install here, for what the land moved: the one
  #    thing it does to this checkout beyond git, and only when asked.
  if [ "$run_prepare" -eq 1 ] && [ -n "$deps_here" ]; then
    local hrc=0 before after hrewrote
    before="$(_aif_land_dirty "$root")"
    AIF_LAND_PREPARE="$prepare"
    AIF_LAND_STATE=installing
    _aif_land_say "prepare" "$deps_here moved — $prepare, here (--prepare)"
    _aif_land_prepare "$root" "$prepare" "$out" || hrc=$?
    after="$(_aif_land_dirty "$root")"
    hrewrote="$(printf '%s\n' "$after" | AIF_LAND_LIST="$before" awk '
      BEGIN { n = split(ENVIRON["AIF_LAND_LIST"], l, "\n"); for (i = 1; i <= n; i++) w[l[i]] = 1 }
      NF && !($0 in w)' | paste -sd ',' - | sed 's/,/, /g')" || hrewrote=""
    if [ "$hrc" -ne 0 ]; then
      dep_line="$deps_here moved — the install here failed (exit $hrc) — what is installed here may not match it: $prepare"
    elif [ -n "$hrewrote" ]; then
      dep_line="$deps_here moved — the install here ($prepare) rewrote $hrewrote — it has to install what the lockfile pins, as it pins it (npm ci, not npm install); what is installed here may not match it, and the rewrite is left to you"
    else
      dep_line="$deps_here moved — installed here ($prepare)"
    fi
    local tail_
    tail_=""
    [ "$hrc" -eq 0 ] || tail_="$(grep -v '^[[:space:]]*$' "$out" | sed 's/\x1b\[[0-9;]*m//g' | tail -8)" || tail_=""
    # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
    aif_land_marker_set "$marker" '.deps_line = $d | .deps_tail = (if $t == "" then null else $t end) | .done += ["install"]' \
      --arg d "$dep_line" --arg t "$tail_" || true
    AIF_LAND_STATE=landed
  fi

  # 9. the card, whoever was waiting on it, the worktree and the branch — each
  #    step once, in the marker (_aif_land_book).
  _aif_land_book "$root" "$marker"
  rm -f "$marker"
  AIF_LAND_MARKER=""
  _aif_land_unlock
  AIF_LAND_STATE=""
  aif_trap_disarm
  rm -f "${out:?}"

  printf '\n'
  printf 'landed:   %s → %s at %s (merge of %s, %s commits)\n' "$ticket" "$target" "${merge:0:7}" "$branch" "$n_commits"
  [ -z "$settled" ] || printf 'settled:  %s\n' "$settled"
  [ -z "$aside" ] || printf 'aside:    %s\n' "$aside"
  printf 'suite:    %s\n' "$suite"
  if [ -n "$dep_line" ]; then
    printf 'deps:     %s\n' "$dep_line"
    [ -z "${tail_:-}" ] || printf '%s\n' "$tail_" | sed 's/^/          /'
  fi
  printf 'board:    %s is in Done  (aif board show %s)\n' "$ticket" "$ticket"
  if [ -n "$AIF_LAND_RELEASED" ]; then
    printf 'released: %s → Ready\n' "$AIF_LAND_RELEASED"
  else
    printf 'released: nothing was waiting on it\n'
  fi
  printf 'cleanup:  %s\n' "$AIF_LAND_CLEANUP"
  return 0
}
