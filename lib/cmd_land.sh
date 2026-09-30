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
#               run record not `built`, uncommitted changes, --prepare with no
#               "prepare" to run — nothing touched
#   merge       aif/<ID> into the checkout's branch, --no-ff so the ticket
#               stays one commit to find. A conflict is aborted and reported,
#               never resolved by a model
#   install     only with --prepare, and only when the merge moved a dependency
#               manifest or lockfile: project.json's "prepare", here
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
# A merge that moves a manifest or a lockfile changes what the suite needs
# installed, and what is installed here is not in the merge: the suite judged
# it against node_modules from before it, went red over a package it lacked,
# and undid a ticket with nothing wrong in it (docs/DEFECTS-6.md #3).
# Installing is not done unasked. "prepare" was written to provision a fresh
# worktree; here it runs in the developer's own checkout, where `npm ci`
# deletes node_modules before it installs, a `cp .env.example .env` beside it
# would overwrite theirs, and a reset cannot take an install back. So by
# default the moved files are only named — before the suite, in a red's
# reason with the command that lands it installed, in a green's summary. With
# --prepare the install runs after the merge and before the suite, and an
# undo runs it again for the lockfile the reset put back.
#
# From the merge to the verdict the developer's branch carries a commit nobody
# has judged, for as long as the install and the suite take. A land stopped
# there — Ctrl-C, a TERM, an error on the way — undoes the merge, leaves the
# card in Review and names what it could not take back (_aif_land_stopped).
#
# It never runs a model and never starts a build. Exit: 0 landed · 1 refused,
# or undone (the card and the comment say why) · 3 the environment cannot land
# anything (not a project, a worktree, the board unreachable) · 130 or 143
# stopped by an INT or a TERM before the verdict, and undone.

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
  card to Needs Human with the reason. Stopped before the verdict — Ctrl-C, a
  TERM — it undoes the merge and leaves the card in Review. The branch is
  untouched either way.

  A merge that moves a dependency manifest or lockfile (package.json,
  package-lock.json, ...) is judged against the dependencies installed here
  before it, and says so — unless --prepare installs them first.

  --no-suite         land without running .test.command on the result
  --keep             keep the worktree and the branch after landing
  --prepare          when the merge moves a manifest or a lockfile, run
                     "prepare" from .aif/project.json HERE before the suite
                     (npm ci replaces node_modules), and again after an undo,
                     for the lockfile it put back
EOF
}

_aif_land_say() {
  printf '%s%-9s%s %s\n' "$AIF_C_DIM" "$1" "$AIF_C_RESET" "$2" >&2
}

# _aif_land_fail <root> <ticket> <headline> <detail-file> <again> [<more>] —
# after the merge was undone: the reason on the card, the card in Needs Human,
# exit 1. <again> is the command that lands it once it is resolved. <more>
# follows the detail, on the card and here: what the red was measured against,
# what became of the install, a better command than <again> when there is one.
_aif_land_fail() {
  local root="$1" ticket="$2" headline="$3" detail="$4" again="$5" more="${6:-}" note
  # A verdict, reached with the merge undone: the stop handler has nothing left
  # to undo, and this exit 1 must not come back through EXIT as a stop.
  aif_trap_disarm
  note="$(mktemp "${TMPDIR:-/tmp}/aif-land-XXXXXX")"
  {
    printf '# %s — not landed\n\n%s\n' "$ticket" "$headline"
    if [ -s "$detail" ]; then
      printf '\n```\n'
      sed 's/\x1b\[[0-9;]*m//g' "$detail" | sed -n '1,20p'
      printf '```\n'
    fi
    [ -z "$more" ] || printf '\n%s\n' "$more"
    printf '\nThe merge was undone and aif/%s is untouched. Rework the ticket, or resolve by hand and run: %s\n' \
      "$ticket" "$again"
  } >"$note"
  (AIF_BOARD_BY="aif land" aif_board_comment "$root" "$ticket" "$note" >/dev/null) || true
  (aif_board_move "$root" "$ticket" needs_human >/dev/null) || true
  rm -f "${note:?}" "${detail:?}"
  aif_err "$headline"
  [ -z "$more" ] || printf '%s\n' "$more" | sed '/./s/^/  /' >&2
  _aif_land_say "board" "$ticket → needs_human, the reason posted"
  exit 1
}

# _aif_land_prepare <root> <prepare> <log> — the project's install, here, rc
# its own. stdin closed, as the worker closes it: the output goes to a file, so
# a prompt would wait for an answer nobody can see.
_aif_land_prepare() {
  local rc=0
  (cd "$1" && eval "$2") </dev/null >"$3" 2>&1 || rc=$?
  return "$rc"
}

# _aif_land_undo <root> <pre> <prepare> — back to the commit from before the
# merge. The tree was clean, so the reset loses nothing git tracks, and an
# install is not something it tracks. <prepare> is the command when this land
# ran it on the merge, and empty when it did not. When it did, what is
# installed here is the merge's, or whatever a failed install left, so it runs
# again for the lockfile the reset put back — and the reset once more after
# it, for anything it rewrote. Prints what became of the install, for the card.
_aif_land_undo() {
  local root="$1" pre="$2" prepare="$3" log rc=0
  git -C "$root" reset --hard "$pre" >/dev/null 2>&1
  [ -n "$prepare" ] || return 0
  _aif_land_say "prepare" "again, for the lockfile the undo put back — $prepare"
  log="$(mktemp "${TMPDIR:-/tmp}/aif-land-XXXXXX")"
  _aif_land_prepare "$root" "$prepare" "$log" || rc=$?
  rm -f "${log:?}"
  git -C "$root" reset --hard "$pre" >/dev/null 2>&1
  if [ "$rc" -eq 0 ]; then
    printf 'The dependencies were installed again, from the lockfile the undo put back.'
  else
    printf 'Installing the dependencies again from the lockfile the undo put back failed (exit %s): what is installed here may not match it. Run:\n\n    %s' \
      "$rc" "$prepare"
  fi
}

# What a stop acts on, in globals, as the worker's handler has it: a trap fires
# with nothing but the signal's name, and on EXIT the locals may already be
# gone. AIF_LAND_PRE is the commit to go back to, and empty whenever there is
# nothing to undo; AIF_LAND_PREPARE is the install, once --prepare started it.
AIF_LAND_ROOT=""
AIF_LAND_PRE=""
AIF_LAND_CARD=""
AIF_LAND_AGAIN=""
AIF_LAND_PREPARE=""
AIF_LAND_OUT=""

# _aif_land_stopped <EXIT|INT|TERM> — the land stopped between its merge and
# its verdict: Ctrl-C, a supervisor's TERM, or an error on the way (an aif_die,
# a command failing under set -e). Each used to leave the merge commit on the
# developer's branch, the card in Review, the worktree gone and, with
# --prepare, half an install — and nothing said so.
#
# The merge is undone: the tree was clean before it, so the reset loses nothing
# git tracks. Nothing else is. The card stays in Review: the land did not
# fail, it was stopped, and a stop decides nothing about the ticket. An install
# --prepare had started is named with its command, not run again — npm ci takes
# minutes, and whoever pressed Ctrl-C wants the prompt back.
#
# Armed with aif_trap_arm just before the merge, and disarmed at the verdict:
# by the land after a green, by _aif_land_fail after an undo.
_aif_land_stopped() {
  local pre="$AIF_LAND_PRE" why target short undone=1
  # Once: the exit an INT ends in comes back through EXIT.
  [ -n "$pre" ] || return 0
  AIF_LAND_PRE=""
  # And whole. This ends the process, so nothing after it relies on errexit,
  # and a second Ctrl-C must not cut the reset in half.
  set +e
  trap '' INT TERM
  case "${1:-EXIT}" in
    INT) why="interrupted" ;;
    TERM) why="terminated" ;;
    *) why="stopped by the error above" ;;
  esac
  git -C "$AIF_LAND_ROOT" reset --hard "$pre" >/dev/null 2>&1 || undone=0
  [ -z "$AIF_LAND_OUT" ] || rm -f "$AIF_LAND_OUT" "$AIF_LAND_OUT.tail"
  printf '\n' >&2
  if [ "$undone" -eq 1 ]; then
    target="$(git -C "$AIF_LAND_ROOT" symbolic-ref --short HEAD 2>/dev/null)"
    short="$(git -C "$AIF_LAND_ROOT" rev-parse --short "$pre" 2>/dev/null)"
    aif_err "$why — the merge was undone: ${target:-HEAD} is back at ${short:-$pre}"
  else
    aif_err "$why — and the merge could not be undone. Run: git -C '$AIF_LAND_ROOT' reset --hard $pre"
  fi
  {
    printf '%s is still in Review, and aif/%s is untouched: a stop decides nothing.\n' \
      "$AIF_LAND_CARD" "$AIF_LAND_CARD"
    if [ -n "$AIF_LAND_PREPARE" ]; then
      printf '"prepare" had started here, and a stop does not run it again: what is\n'
      printf "installed may be partial, or the merge's. Install from the lockfile the\n"
      printf 'undo put back:\n\n    %s\n\n' "$AIF_LAND_PREPARE"
    fi
    printf 'To land it: %s\n' "$AIF_LAND_AGAIN"
  } | sed '/./s/^/  /' >&2
  case "${1:-EXIT}" in
    INT) exit 130 ;;
    TERM) exit 143 ;;
  esac
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
    # From here to the verdict, a stop undoes the merge (_aif_land_stopped).
    # Armed before git merges rather than after: a merge cut off halfway
    # leaves a half-merged tree, and the same reset clears that.
    AIF_LAND_ROOT="$root"
    AIF_LAND_PRE="$pre"
    AIF_LAND_CARD="$ticket"
    AIF_LAND_AGAIN="$rerun"
    AIF_LAND_OUT="$out"
    aif_trap_arm "_aif_land_stopped"
    if git -C "$root" merge --no-ff --no-edit -m "aif: land $ticket — $title" "$branch" >"$out" 2>&1; then
      merged=1
      _aif_land_say "merge" "$branch into $target — $n_commits commit(s)"
    else
      git -C "$root" merge --abort >/dev/null 2>&1 || git -C "$root" reset --hard "$pre" >/dev/null 2>&1
      _aif_land_fail "$root" "$ticket" \
        "$branch does not merge cleanly into $target — a conflict is a human's to resolve, and nothing here resolves it" "$out" "$again"
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

  # 3. the dependencies: the manifests and lockfiles the merge moved, pre..HEAD.
  #    Installed here with --prepare, and named without it.
  local deps="" prepared=0 prep_rc=0 rewrote="" headline="" more=""
  if [ "$merged" -eq 1 ]; then
    deps="$(git -C "$root" -c core.quotePath=false diff --name-only "$pre" HEAD 2>/dev/null |
      grep -E "$AIF_DEP_MANIFESTS|$AIF_DEP_LOCKFILES" | sort -u | paste -sd ',' - | sed 's/,/, /g')" || deps=""
  fi
  if [ -z "$deps" ]; then
    [ "$run_prepare" -eq 0 ] ||
      _aif_land_say "prepare" "not run — no dependency manifest or lockfile moved"
  elif [ "$run_prepare" -eq 0 ]; then
    _aif_land_say "deps" "$deps moved — not installed here${prepare:+ (--prepare installs them)}"
  else
    _aif_land_say "prepare" "$deps moved — $prepare"
    prepared=1
    # From here a stop cannot say what is installed, so it names the install.
    AIF_LAND_PREPARE="$prepare"
    _aif_land_prepare "$root" "$prepare" "$out" || prep_rc=$?
    # An install from the lockfile leaves the tree as the merge made it. One
    # that rewrites a tracked file installed something the merge did not pin,
    # and would leave this checkout dirty besides.
    rewrote="$(git -C "$root" -c core.quotePath=false diff --name-only HEAD 2>/dev/null |
      paste -sd ',' - | sed 's/,/, /g')" || rewrote=""
    if [ "$prep_rc" -ne 0 ] || [ -n "$rewrote" ]; then
      # Install tools print the reason last.
      { grep -v '^[[:space:]]*$' "$out" | tail -20 >"$out.tail"; } || true
      mv "$out.tail" "$out"
      if [ "$prep_rc" -ne 0 ]; then
        headline="the merge moved $deps, and \"prepare\" ($prepare) failed on the result (exit $prep_rc) — the merge was undone"
      else
        headline="the merge moved $deps, and \"prepare\" ($prepare) rewrote $rewrote — it has to install what the lockfile pins, as it pins it (npm ci, not npm install); the merge was undone"
      fi
      more="$(_aif_land_undo "$root" "$pre" "$prepare")"
      _aif_land_fail "$root" "$ticket" "$headline" "$out" "$again" "$more"
    fi
  fi

  # 4. the suite, on the result. Exit code first; then the report the gates
  #    read, because a runner that exits 0 with failures in the report exists
  #    (the offline harness's stub is one), and green does not trust the exit
  #    code alone either.
  local project test_cmd suite suite_ran=0 suite_rc=0 report_path="" failures=0 junit
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
      if [ "$prepared" -eq 1 ]; then
        more="The merge moved $deps, and the suite ran with them installed here ($prepare). $(_aif_land_undo "$root" "$pre" "$prepare")"
      else
        _aif_land_undo "$root" "$pre" ""
        if [ -n "$deps" ]; then
          more="The merge moved $deps, and the suite ran against the dependencies installed here before it — the red may be that install, not the change. "
          if [ -n "$prepare" ]; then
            more="${more}To land it with them installed from the lockfile, here ($prepare):"
          else
            more="${more}There is no \"prepare\" in .aif/project.json to install them with: set it (e.g. \"npm ci\"), then:"
          fi
          more="$more$(printf '\n\n    %s --prepare' "$again")"
        fi
      fi
      _aif_land_fail "$root" "$ticket" \
        "the suite is red on $target with $branch merged (exit $suite_rc, $failures failing) — the merge was undone" "$out" "$again" "$more"
    fi
    suite="green ($test_cmd)"
    suite_ran=1
    _aif_land_say "suite" "green"
  fi
  # The verdict, and the merge stays. From here a stop leaves it landed, with
  # the branch and the board still to do.
  aif_trap_disarm
  rm -f "${out:?}"

  # What is installed now, when the merge moved what should be.
  local dep_line=""
  if [ "$prepared" -eq 1 ]; then
    dep_line="$deps moved — installed here ($prepare)"
  elif [ -n "$deps" ]; then
    dep_line="$deps moved — not installed here"
    [ "$suite_ran" -eq 0 ] || dep_line="$dep_line; the suite ran against the install from before the merge"
    if [ -n "$prepare" ]; then
      dep_line="$dep_line. Install them: $prepare"
    else
      dep_line="$dep_line. Install them from the lockfile"
    fi
  fi

  # 5. the branch, and the card.
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
    [ -z "$dep_line" ] || printf -- '- dependencies: %s\n' "$dep_line"
    printf -- '- worktree %s; branch %s\n' "$wt_note" "$br_note"
  } >"$note"
  (AIF_BOARD_BY="aif land" aif_board_comment "$root" "$ticket" "$note" >/dev/null) ||
    aif_warn "could not post the landing note to the card — run: aif board comment $ticket <file>"
  rm -f "${note:?}"
  if ! (aif_board_move "$root" "$ticket" "done" >/dev/null); then
    aif_warn "could not move $ticket to Done on the board — run: aif board move $ticket done"
  fi

  # 6. whoever was waiting on it.
  local released
  released="$(_aif_land_release "$root" "$ticket")"

  printf '\n'
  printf 'landed:   %s → %s at %s' "$ticket" "$target" "$sha"
  [ "$merged" -eq 0 ] || printf ' (merge of %s, %s commits)' "$branch" "$n_commits"
  printf '\n'
  printf 'suite:    %s\n' "$suite"
  [ -z "$dep_line" ] || printf 'deps:     %s\n' "$dep_line"
  printf 'board:    %s is in Done  (aif board show %s)\n' "$ticket" "$ticket"
  if [ -n "$released" ]; then
    printf 'released: %s → Ready\n' "$released"
  else
    printf 'released: nothing was waiting on it\n'
  fi
  printf 'cleanup:  worktree %s; branch %s %s\n' "$wt_note" "$branch" "$br_note"
  return 0
}
