#!/usr/bin/env bash
#
# The Backlog release sweep — `aif board release [--dry-run]`. Sourced by
# bin/aif; not meant to be executed directly.
#
# Backlog holds four kinds of card the code never told apart
# (docs/AUTOPILOT-RESEARCH.md §4.4): the later slices of a request, waiting on
# the ones before them through `depends_on`; the project manager's `rework:`
# cards, which the analyst takes back — not a move; the cards a human set
# aside; and, on Trello, cards made by hand with no ticket behind them. Only
# the first kind is ever released, and until now one thing released it: `aif
# land`, for the tickets that name the one it just landed, once every other
# dependency is Done (_aif_land_release, lib/cmd_land.sh). That left a gap. A
# ticket merged by hand, a land whose move failed on the board, a dependent
# cut after its dependency landed — each leaves a card in Backlog that nothing
# will ever release. This is the pass that does: every Backlog card with a
# `depends_on`, judged on its own, from the command line or by whatever runs
# a shift.
#
# Why a sweep of its own, and not the land's function with an optional id
# (research §6.11, verification 4): that function takes only the cards that
# NAME the landed ticket (`grep -qx -- "$ticket"`), exempts that ticket from
# its Done check, and with an empty id matches nothing; it reads the board
# with `|| statuses="[]"`, so a board it could not ask looked like a Backlog
# with nothing waiting; and it comments before it moves, with a text that
# names the land. All of that is right for a land — the card is this land's,
# the release follows the merge it just made — and wrong for a pass that
# judges every dependency and runs again and again. The land's path stays as
# it is. This one checks every `depends_on`, dies when the board cannot be
# read, and moves nothing it has not been able to write on.
#
# Why Done is not enough. The project manager puts a cancelled ticket in Done
# too, under a `cancelled:` comment, and its branch never merges
# (sets/claude/skills/aif-pjm/SKILL.md, "cancel"). A dependent released on
# the column alone would be built on a tree without the slice it needs
# (verification 4). So a dependency counts only when the branch of the main
# checkout carries the merge commit `aif land` writes — `aif: land <ID> —
# <title>`, found with `git log --grep` — and a Done card without one is named
# as what it probably is, a merge by hand, with the command that releases the
# dependent on purpose.
#
# Why any head holds the card: a Backlog card nothing has written on is a
# slice waiting its turn, and that is the only card this pass may move. One
# with a head has been somewhere — reworked (`rework:`, back through the
# analyst, who returns it to Ready in their own time), blocked, cancelled,
# built and dragged back from Review, released and dragged back from Ready —
# and a role or the human put it in Backlog on purpose. A dependency landing
# does not outrank that; the line names the head, and the human's move is one
# command away. Only the newest head counts (aif_board_last_line): a card
# reworked and cut again carries the analyst's fresh card, and the pjm's
# `rework:` is no longer the newest thing on it.
#
# Why the hold labels: on the Opes board a human marks what is set aside with
# `parked` and `retired-direction`, a convention the code did not know
# (research §2.3), and a sweep that ignored it would release exactly what was
# deliberately put down. AIF_RELEASE_HOLD_LABELS names the set, for a board
# that says it with other words.
#
# Why the bottom of Ready, never the top: the top is the project manager's
# order — `aif board move --top` is how a human says "this one first" — and a
# release is the queue growing at its tail, as the land does it. The comment
# on the card is the human's handle: who moved it and on what grounds, so a
# card they want back in Backlog is dragged there knowing what dragged it out.
#
# Why loud on an unreadable board: a pass that said "nothing to release"
# because the board did not answer would be read by a shift as a quiet
# Backlog, and the shift would go on (research §6.11, verification 3;
# docs/DEFECTS.md 14.7 is the same mistake in the comments read). So the one
# status read dies with the reason, and a card whose comments could not be
# read is named and left alone while the rest of the pass still runs.
#
# --dry-run prints the same lines and touches nothing: the human's view of
# what waits on what, after a merge by hand or before letting a shift loose.

# _aif_release_why <captured output> — the first line of an aif_die caught
# inside `$(…)`, bare: the `error:` prefix and the colour codes off, so it can
# follow a dash on a line of this report (aif_board_last_line does the same;
# docs/DEFECTS.md 14.7).
_aif_release_why() {
  local esc
  esc="$(printf '\033')"
  printf '%s\n' "$1" | sed -n 1p | sed "s/$esc\[[0-9;]*m//g; s/^error: //"
}

# aif_release_sweep <root> <by> <dry_run 0|1> — the pass over Backlog. One
# line per card it considered, on stdout — `<ID>  <what>` — and a count line
# last; rc 0 whenever the board was read, whatever the cards said, and
# aif_die when it was not. <by> is the voice of the comment and the card's
# `by`: `aif board release` from the command line.
#
# The tickets and the landed commits are the MAIN checkout's: a worktree's
# HEAD is a ticket's branch, which carries a land only when it was brought
# onto main, and the board is resolved through the common dir already.
aif_release_sweep() {
  local root="$1" by="$2" dry="${3:-0}"
  local main statuses why re hold f t deps d col labels l held head rc wait landed note deps_line
  local n_released=0 n_held=0 n_waiting=0 n_unread=0 n_failed=0 verb="released"
  main="$(aif_main_root "$root")"
  [ "$dry" -eq 0 ] || verb="would release"

  # One read of the board, first and loud. Every verdict below rests on it,
  # so a board that did not answer is the whole pass refused, not a pass with
  # nothing to say. The adapter's die runs in the substitution's subshell;
  # what it said is in the captured text, and goes after the dash.
  rc=0
  statuses="$(aif_board_status_json "$root" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$statuses" | jq -e 'type == "array"' >/dev/null 2>&1; then
    why="$(_aif_release_why "$statuses")"
    aif_die "the board could not be read — nothing released${why:+ — $why}"
  fi

  re="$(aif_board_ticket_re "$root")"
  [ -n "$re" ] || re='^[A-Z]{2,10}-[0-9]+$'
  hold="${AIF_RELEASE_HOLD_LABELS:-parked retired-direction}"

  for f in "$main/$AIF_TASKS_DIR"/*/ticket.md; do
    [ -f "$f" ] || continue
    t="$(basename "$(dirname "$f")")"
    printf '%s\n' "$t" | grep -Eq -- "$re" || continue
    col="$(printf '%s' "$statuses" | jq -r --arg t "$t" '[ .[] | select(.ticket == $t) ] | .[0].column // empty')"
    [ "$col" = "backlog" ] || continue
    # A card with nothing to wait on is not this pass's: it is in Backlog
    # because nobody has put it in Ready, and that is the project manager's
    # call, not a dependency's.
    deps="$(aif_meta_json "$f" 2>/dev/null | jq -r '(.depends_on // [])[]' 2>/dev/null)" || deps=""
    [ -n "$deps" ] || continue

    # The human's hold, first: a label beats everything the tickets say.
    labels="$(printf '%s' "$statuses" | jq -r --arg t "$t" '[ .[] | select(.ticket == $t) ] | .[0].labels // [] | .[]')"
    held=""
    for l in $hold; do
      if printf '%s\n' "$labels" | grep -qx -- "$l"; then
        held="$l"
        break
      fi
    done
    if [ -n "$held" ]; then
      printf '%s  held: label %s\n' "$t" "$held"
      n_held=$((n_held + 1))
      continue
    fi

    # Then the newest head on the card: any head holds it (see the header).
    # rc 2 is the board, not the card: the why comes back on the captured
    # stream (aif_board_last_line prints it bare), and the card is left for a
    # pass that can read it.
    rc=0
    head="$(aif_board_last_line "$root" "$t" 2>&1)" || rc=$?
    case "$rc" in
      0)
        printf '%s  held: %s\n' "$t" "$head"
        n_held=$((n_held + 1))
        continue
        ;;
      1) ;;
      *)
        printf '%s  not read — %s; left alone\n' "$t" "${head:-the card could not be read}"
        n_unread=$((n_unread + 1))
        continue
        ;;
    esac

    # Every dependency: on the board, in Done, and landed on this branch. The
    # first one that is not says why the card waits; the others are not asked.
    wait=""
    for d in $deps; do
      col="$(printf '%s' "$statuses" | jq -r --arg t "$d" '[ .[] | select(.ticket == $t) ] | .[0].column // empty')"
      if [ -z "$col" ]; then
        wait="waits on $d (no card on the board)"
        break
      fi
      if [ "$col" != "done" ]; then
        wait="waits on $d ($col)"
        break
      fi
      # --fixed-strings: the subject is matched as text, not a regex, and the
      # trailing space keeps AIF-1's land from standing in for AIF-10's.
      landed="$(git -C "$main" log --fixed-strings --grep "aif: land $d — " -1 --format=%h 2>/dev/null)" || landed=""
      if [ -z "$landed" ]; then
        wait="waits on $d (Done, but no \"aif: land $d\" commit here — merged by hand? then: aif board move $t ready)"
        break
      fi
    done
    if [ -n "$wait" ]; then
      printf '%s  %s\n' "$t" "$wait"
      n_waiting=$((n_waiting + 1))
      continue
    fi

    deps_line="$(printf '%s\n' "$deps" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
    if [ "$dry" -eq 1 ]; then
      printf '%s  would release → Ready (bottom)\n' "$t"
      n_released=$((n_released + 1))
      continue
    fi

    # The comment, then the move — and no move without the comment. A card in
    # Ready with nothing on it to say what put it there is a hand-drag to
    # everyone who looks, on a shared board most of all; a card left in
    # Backlog is tried again next pass. A move that failed after its comment
    # is named with the command that finishes it (the PUT is retried by the
    # adapter, the POST is not — docs/DEFECTS.md 13.8 — so this is the rarer
    # of the two).
    note="$(mktemp "${TMPDIR:-/tmp}/aif-release-XXXXXX")"
    printf 'released by %s: every ticket it depends on is Done and landed (%s)\n' "$by" "$deps_line" >"$note"
    if ! (AIF_BOARD_BY="$by" aif_board_comment "$root" "$t" "$note" >/dev/null); then
      rm -f "${note:?}"
      printf '%s  not released — the comment could not be posted; left in Backlog for the next pass\n' "$t"
      n_failed=$((n_failed + 1))
      continue
    fi
    rm -f "${note:?}"
    if (aif_board_move "$root" "$t" ready >/dev/null); then
      printf '%s  released → Ready (bottom)\n' "$t"
      n_released=$((n_released + 1))
    else
      printf '%s  not released — the comment is on the card but the move failed; run: aif board move %s ready\n' "$t" "$t"
      n_failed=$((n_failed + 1))
    fi
  done

  printf '%s %d · held %d · waiting %d · not read %d' "$verb" "$n_released" "$n_held" "$n_waiting" "$n_unread"
  [ "$n_failed" -eq 0 ] || printf ' · not released %d' "$n_failed"
  if [ $((n_released + n_held + n_waiting + n_unread + n_failed)) -eq 0 ]; then
    printf ' — no Backlog card names a depends_on'
  fi
  printf '\n'
  return 0
}
