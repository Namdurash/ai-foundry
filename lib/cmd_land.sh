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
#   refuse      not the main checkout, no branch, the card not in Review, the
#               run record not `built`, uncommitted changes — nothing touched
#   merge       aif/<ID> into the checkout's branch, --no-ff so the ticket
#               stays one commit to find. A conflict is aborted and reported,
#               never resolved by a model
#   suite       .test.command on the RESULT, here: the gates proved the branch
#               alone, this proves it with everything landed since. Red undoes
#               the merge — the tree was clean, so a reset to the sha from
#               before it loses nothing — and reports
#   card        → Done with what happened as a comment; a failure after the
#               merge → Needs Human with the same comment
#   release     every ticket whose `depends_on` names this one, and whose other
#               dependencies are Done, moves Backlog → Ready. That is how a
#               request's slices flow without the project manager touching
#               each one
#
# It never runs a model and never starts a build. Exit: 0 landed · 1 refused,
# or undone (the card and the comment say why) · 3 the environment cannot land
# anything (not a project, a worktree, the board unreachable).

_aif_land_usage() {
  cat <<EOF
usage: aif land <ticket> [options]

  The yes after review, as one command: merge aif/<ticket> into this checkout's
  branch, run the suite on the result, move the card to Done, remove the
  worktree and the branch, and release the tickets that were waiting for this
  one — those whose depends_on names it — from Backlog to Ready.

  Refused, touching nothing, unless this is the main checkout, the branch
  exists, the card is in Review, the run ended built, and nothing here is
  uncommitted. A merge conflict or a red suite undoes the merge and moves the
  card to Needs Human with the reason; the branch is untouched either way.

  --no-suite         land without running .test.command on the result
  --keep             keep the worktree and the branch after landing
EOF
}

_aif_land_say() {
  printf '%s%-9s%s %s\n' "$AIF_C_DIM" "$1" "$AIF_C_RESET" "$2" >&2
}

# _aif_land_fail <root> <ticket> <headline> <detail-file> — after the merge was
# undone: the reason on the card, the card in Needs Human, exit 1.
_aif_land_fail() {
  local root="$1" ticket="$2" headline="$3" detail="$4" note
  note="$(mktemp "${TMPDIR:-/tmp}/aif-land-XXXXXX")"
  {
    printf '# %s — not landed\n\n%s\n' "$ticket" "$headline"
    if [ -s "$detail" ]; then
      printf '\n```\n'
      sed 's/\x1b\[[0-9;]*m//g' "$detail" | sed -n '1,20p'
      printf '```\n'
    fi
    printf '\nThe merge was undone and aif/%s is untouched. Rework the ticket, or resolve by hand and run: aif land %s\n' \
      "$ticket" "$ticket"
  } >"$note"
  (AIF_BOARD_BY="aif land" aif_board_comment "$root" "$ticket" "$note" >/dev/null) || true
  (aif_board_move "$root" "$ticket" needs_human >/dev/null) || true
  rm -f "${note:?}" "${detail:?}"
  aif_err "$headline"
  _aif_land_say "board" "$ticket → needs_human, the reason posted"
  exit 1
}

# _aif_land_column <root> <ticket> — the card's column, or empty when there is
# no card.
_aif_land_column() {
  aif_board_show_json "$1" "$2" 2>/dev/null | jq -r '.column // empty' 2>/dev/null || true
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

aif_cmd_land() {
  local ticket="" run_suite=1 keep=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-suite) run_suite=0 ;;
      --keep) keep=1 ;;
      -h | --help)
        _aif_land_usage
        return 0
        ;;
      -*) aif_die "unknown option: $1" ;;
      *) ticket="$1" ;;
    esac
    shift
  done
  [ -n "$ticket" ] || aif_die "usage: aif land <ticket> [--no-suite] [--keep]"

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
  local column
  column="$(_aif_land_column "$root" "$ticket")"
  case "$column" in
    review) ;;
    done)
      printf '%s is already in Done — nothing to land\n' "$ticket"
      return 0
      ;;
    "") aif_die "$ticket has no card on the board" ;;
    *) aif_die "$ticket is in $column, not Review — landing is the yes after a review. When it has been reviewed: aif board move $ticket review" ;;
  esac

  # The run record travels on the branch. A card in Review whose run did not
  # end `built` is a card somebody moved by hand.
  local status
  status="$(git -C "$root" show "$branch:$AIF_TASKS_DIR/$ticket/run.json" 2>/dev/null |
    jq -r '.status // empty' 2>/dev/null)" || status=""
  [ "$status" = "built" ] ||
    aif_die "the run on $branch did not end built (status: ${status:-no run record}) — nothing to land"

  # Nothing of the developer's is put at risk: the merge, and its undoing on a
  # red suite, happen in a tree with no uncommitted tracked changes.
  [ -z "$(git -C "$root" status --porcelain --untracked-files=no 2>/dev/null)" ] ||
    aif_die "uncommitted changes in this checkout — commit or stash them before landing"
  local target pre
  target="$(git -C "$root" symbolic-ref --short HEAD 2>/dev/null)" ||
    aif_die "HEAD is detached — check out the branch to land onto"
  pre="$(git -C "$root" rev-parse HEAD)"

  local title
  title="$(git -C "$root" show "$branch:$AIF_TASKS_DIR/$ticket/ticket.md" 2>/dev/null |
    sed -n 's/^# *//p' | head -1 | sed "s/^$ticket *[—:-]* *//")"
  [ -n "$title" ] || title="$ticket"

  printf '\n%sland%s %s → %s\n\n' "$AIF_C_BOLD" "$AIF_C_RESET" "$ticket" "$target" >&2

  # 1. the merge. --no-ff even when a fast-forward is possible: the ticket
  #    stays one commit to find, revert, or bisect to.
  local out merged=0 n_commits=0
  out="$(mktemp "${TMPDIR:-/tmp}/aif-land-XXXXXX")"
  if git -C "$root" merge-base --is-ancestor "$branch" HEAD 2>/dev/null; then
    _aif_land_say "merge" "$branch is already in $target"
  else
    n_commits="$(git -C "$root" rev-list --count "HEAD..$branch" 2>/dev/null || printf '?')"
    if git -C "$root" merge --no-ff --no-edit -m "aif: land $ticket — $title" "$branch" >"$out" 2>&1; then
      merged=1
      _aif_land_say "merge" "$branch into $target — $n_commits commit(s)"
    else
      git -C "$root" merge --abort >/dev/null 2>&1 || git -C "$root" reset --hard "$pre" >/dev/null 2>&1
      _aif_land_fail "$root" "$ticket" \
        "$branch does not merge cleanly into $target — a conflict is a human's to resolve, and nothing here resolves it" "$out"
    fi
  fi

  # 2. the worktree, before the suite: a runner that globs from the project
  #    root would otherwise collect the ticket's checkout beside the real tree.
  local wt="$root/$AIF_WORK_WORKTREES/$ticket" wt_note="none"
  if [ -e "$wt" ]; then
    if [ "$keep" -eq 1 ]; then
      wt_note="kept at ${wt#"$root"/}"
    else
      git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "${wt:?}"
      git -C "$root" worktree prune >/dev/null 2>&1 || true
      wt_note="removed ${wt#"$root"/}"
    fi
  fi

  # 3. the suite, on the result. Exit code first; then the report the gates
  #    read, because a runner that exits 0 with failures in the report exists
  #    (the offline harness's stub is one), and green does not trust the exit
  #    code alone either.
  local project test_cmd suite suite_rc=0 report_path="" failures=0 junit
  project="$(aif_project_config "$root")"
  test_cmd="$(jq -r '.test.command // empty' "$project" 2>/dev/null)"
  if [ "$run_suite" -eq 0 ]; then
    suite="skipped (--no-suite)"
  elif [ -z "$test_cmd" ]; then
    suite="skipped — project.json names no test command"
  else
    _aif_land_say "suite" "$test_cmd"
    report_path="$(jq -r '.test.report.path // empty' "$project" 2>/dev/null)"
    [ -z "$report_path" ] || rm -f "${root:?}/${report_path:?}"
    (cd "$root" && eval "$test_cmd") >"$out" 2>&1 || suite_rc=$?
    junit="$(dirname "$(aif_gate_path "$root" ready)")/junit.py"
    if [ "$suite_rc" -eq 0 ] && [ -n "$report_path" ] && [ -f "$root/$report_path" ] &&
      [ -f "$junit" ] && aif_have python3; then
      failures="$(python3 "$junit" "$root/$report_path" 2>/dev/null |
        jq '[ .[] | select(.status == "failure" or .status == "error") ] | length' 2>/dev/null)" || failures=0
      [ -n "$failures" ] || failures=0
    fi
    if [ "$suite_rc" -ne 0 ] || [ "$failures" -gt 0 ]; then
      git -C "$root" reset --hard "$pre" >/dev/null 2>&1
      _aif_land_fail "$root" "$ticket" \
        "the suite is red on $target with $branch merged (exit $suite_rc, $failures failing) — the merge was undone" "$out"
    fi
    suite="green ($test_cmd)"
    _aif_land_say "suite" "green"
  fi
  rm -f "${out:?}"

  # 4. the branch, and the card.
  local br_note="kept"
  if [ "$keep" -eq 0 ]; then
    if git -C "$root" branch -d "$branch" >/dev/null 2>&1; then
      br_note="deleted"
    else
      aif_warn "could not delete $branch — it is merged; remove it by hand: git branch -D $branch"
    fi
  fi

  local sha note
  sha="$(git -C "$root" rev-parse --short HEAD)"
  note="$(mktemp "${TMPDIR:-/tmp}/aif-land-XXXXXX")"
  # shellcheck disable=SC2016  # the backticks are markdown on the card, not substitution
  {
    printf '# %s — landed\n\n' "$ticket"
    if [ "$merged" -eq 1 ]; then
      printf -- '- merged `%s` into `%s` at `%s` (%s commits)\n' "$branch" "$target" "$sha" "$n_commits"
    else
      printf -- '- `%s` was already in `%s` (at `%s`)\n' "$branch" "$target" "$sha"
    fi
    printf -- '- suite on the result: %s\n' "$suite"
    printf -- '- worktree %s; branch %s\n' "$wt_note" "$br_note"
  } >"$note"
  (AIF_BOARD_BY="aif land" aif_board_comment "$root" "$ticket" "$note" >/dev/null) ||
    aif_warn "could not post the landing note to the card — run: aif board comment $ticket <file>"
  rm -f "${note:?}"
  if ! (aif_board_move "$root" "$ticket" "done" >/dev/null); then
    aif_warn "could not move $ticket to Done on the board — run: aif board move $ticket done"
  fi

  # 5. whoever was waiting on it.
  local released
  released="$(_aif_land_release "$root" "$ticket")"

  printf '\n'
  printf 'landed:   %s → %s at %s' "$ticket" "$target" "$sha"
  [ "$merged" -eq 0 ] || printf ' (merge of %s, %s commits)' "$branch" "$n_commits"
  printf '\n'
  printf 'suite:    %s\n' "$suite"
  printf 'board:    %s is in Done  (aif board show %s)\n' "$ticket" "$ticket"
  if [ -n "$released" ]; then
    printf 'released: %s → Ready\n' "$released"
  else
    printf 'released: nothing was waiting on it\n'
  fi
  printf 'cleanup:  worktree %s; branch %s %s\n' "$wt_note" "$branch" "$br_note"
  return 0
}
