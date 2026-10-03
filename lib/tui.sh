#!/usr/bin/env bash
#
# The loop's dashboard: one frame of `aif work --loop` on a terminal — the loop
# in the middle, in blue; each worker around it, in orange, joined to it by a
# line whose colour is that worker's state. Sourced by bin/aif; not meant to
# be executed directly.
#
# A pure function of what the loop knows. aif_tui_frame builds the frame from
# the globals below into AIF_TUI_FRAME and nothing here touches the terminal's
# modes, the board or a worker — lib/cmd_work.sh does that. So a frame renders
# from a fixture with no terminal at all, which is how scripts/check-work.sh
# looks at it (scenario 41).
#
# Every width is counted in characters, never bytes. bash's printf pads by
# bytes, so a Cyrillic title — two bytes a letter — came out half as wide as
# it was told to be, and every border after it moved; ${#s} and ${s:0:n} count
# characters only under a UTF-8 locale. aif_tui_init is handed one in
# AIF_TUI_UTF8, and the measuring functions borrow it as a local LC_CTYPE —
# bin/aif has already demoted LC_ALL, which would override it
# (docs/FINDINGS.md #25).
#
# What the caller sets, before aif_tui_init and aif_tui_frame:
#
#   AIF_TUI_COLS, AIF_TUI_ROWS    the terminal's size
#   AIF_TUI_COLOR, AIF_TUI_256    colour at all; 256 colours (orange is 208)
#   AIF_TUI_UNICODE               box drawing, or ASCII where the locale is not UTF-8
#   AIF_TUI_UTF8                  a UTF-8 locale to measure text in
#   AIF_TUI_NOW                   the time the frame shows
#   AIF_TUI_PARALLEL              how many workers at most
#   AIF_TUI_STARTED               when the loop started
#   AIF_TUI_READY                 the cards in Ready it has not taken, in order
#   AIF_TUI_BUILT, _BLOCKED, _STOPPED   how the runs so far ended
#   AIF_TUI_LOAD, AIF_TUI_DISK    "6.2/14", "41 GB" — what parallel runs use up
#   AIF_TUI_STATUS, _STATUS_TONE  the loop's one line about itself
#   AIF_TUI_EVENTS                the last events, "<tone>|<HH:MM>|<text>" per line
#   AIF_TUI_SEL                   the selected worker's slot
#   AIF_TUI_BOTTOM, AIF_TUI_LOG   "events", or "log" and the selected worker's log
#   AIF_TUI_TYP_plan, _tests, _implement   a station's usual length, in seconds
#   AIF_LS_ID[i], AIF_LS_RESULT[i], AIF_LS_KIND[i], AIF_LS_LIVE[i],
#   AIF_LS_START[i], AIF_LS_END[i], AIF_LS_PCT[i], AIF_LS_PSTAGE[i]
#                                 per slot, 1..AIF_TUI_PARALLEL: the card, how its
#                                 run ended (running, built, blocked, stopped,
#                                 env), the worker's live state as it wrote it
#                                 (lib/cmd_work.sh, _aif_work_live), and the
#                                 progress shown last, so it never goes back
#                                 within a stage

# The stations, in order, and where each sits on a worker's bar: what is
# measured is the stage reached; within a stage, the time spent against the
# station's usual length, never past nine tenths of its share.
AIF_TUI_STAGES="plan tests implement"

# aif_tui_init — colours and line-drawing for this terminal. The colours are
# read through ${!name} by the functions below, which a linter cannot follow.
# shellcheck disable=SC2034
aif_tui_init() {
  local e=$'\033'
  AIF_TUI_C_reset="" AIF_TUI_C_orange="" AIF_TUI_C_orangeb="" AIF_TUI_C_blue="" AIF_TUI_C_blueb=""
  AIF_TUI_C_sel="" AIF_TUI_C_green="" AIF_TUI_C_red="" AIF_TUI_C_yellow="" AIF_TUI_C_dim=""
  AIF_TUI_C_bold=""
  if [ "${AIF_TUI_COLOR:-0}" = 1 ]; then
    AIF_TUI_C_reset="${e}[0m"
    if [ "${AIF_TUI_256:-0}" = 1 ]; then
      AIF_TUI_C_orange="${e}[38;5;208m" AIF_TUI_C_orangeb="${e}[1;38;5;208m"
      AIF_TUI_C_blue="${e}[38;5;75m" AIF_TUI_C_blueb="${e}[1;38;5;75m"
    else
      AIF_TUI_C_orange="${e}[33m" AIF_TUI_C_orangeb="${e}[1;33m"
      AIF_TUI_C_blue="${e}[34m" AIF_TUI_C_blueb="${e}[1;34m"
    fi
    AIF_TUI_C_sel="${e}[7;1m" AIF_TUI_C_green="${e}[32m" AIF_TUI_C_red="${e}[31m"
    AIF_TUI_C_yellow="${e}[33m" AIF_TUI_C_dim="${e}[2m" AIF_TUI_C_bold="${e}[1m"
  fi
  if [ "${AIF_TUI_UNICODE:-1}" = 1 ]; then
    AIF_TUI_G_tl="╭" AIF_TUI_G_tr="╮" AIF_TUI_G_bl="╰" AIF_TUI_G_br="╯" AIF_TUI_G_h="─" AIF_TUI_G_v="│"
    AIF_TUI_G_up="┴" AIF_TUI_G_down="┬" AIF_TUI_G_dh="╌" AIF_TUI_G_dv="╎" AIF_TUI_G_full="█" AIF_TUI_G_empty="░"
    AIF_TUI_G_run="●" AIF_TUI_G_prep="◌" AIF_TUI_G_ok="✓" AIF_TUI_G_no="✗" AIF_TUI_G_halt="■"
    AIF_TUI_G_sel="▸" AIF_TUI_G_to="→" AIF_TUI_G_sep="·" AIF_TUI_G_more="…" AIF_TUI_G_next="›"
  else
    AIF_TUI_G_tl="+" AIF_TUI_G_tr="+" AIF_TUI_G_bl="+" AIF_TUI_G_br="+" AIF_TUI_G_h="-" AIF_TUI_G_v="|"
    AIF_TUI_G_up="+" AIF_TUI_G_down="+" AIF_TUI_G_dh="." AIF_TUI_G_dv=":" AIF_TUI_G_full="#" AIF_TUI_G_empty="."
    AIF_TUI_G_run="*" AIF_TUI_G_prep="o" AIF_TUI_G_ok="v" AIF_TUI_G_no="x" AIF_TUI_G_halt="#"
    AIF_TUI_G_sel=">" AIF_TUI_G_to="->" AIF_TUI_G_sep="." AIF_TUI_G_more="~" AIF_TUI_G_next=">"
  fi
}

# aif_tui_len <text> — its width in characters, into AIF_TUI_N.
aif_tui_len() {
  local LC_CTYPE="${AIF_TUI_UTF8:-${LC_CTYPE:-}}"
  AIF_TUI_N=${#1}
}

# aif_tui_rep <n> <glyph> — the glyph n times, into AIF_TUI_OUT.
aif_tui_rep() {
  local s
  AIF_TUI_OUT=""
  [ "$1" -gt 0 ] || return 0
  printf -v s '%*s' "$1" ''
  AIF_TUI_OUT="${s// /$2}"
}

# aif_tui_line <width> <tone> <text> [<tone> <text> …] — one line of exactly
# <width> characters, each piece in its tone, into AIF_TUI_OUT: cut with an
# ellipsis where it is wider, padded with spaces where it is narrower.
aif_tui_line() {
  local LC_CTYPE="${AIF_TUI_UTF8:-${LC_CTYPE:-}}"
  local width="$1" out="" used=0 tone text n room c pad
  shift
  while [ $# -ge 2 ]; do
    tone="$1"
    text="$2"
    shift 2
    room=$((width - used))
    [ "$room" -gt 0 ] || break
    n=${#text}
    if [ "$n" -gt "$room" ]; then
      text="${text:0:$((room - 1))}$AIF_TUI_G_more"
      n=$room
    fi
    c="AIF_TUI_C_$tone"
    if [ -n "${!c-}" ]; then
      out="$out${!c}$text$AIF_TUI_C_reset"
    else
      out="$out$text"
    fi
    used=$((used + n))
  done
  if [ "$used" -lt "$width" ]; then
    printf -v pad '%*s' "$((width - used))" ''
    out="$out$pad"
  fi
  AIF_TUI_OUT="$out"
}

# aif_tui_border <width> <tone> <left> <right> [<pos> <tone> <text> …] — a box's
# top or bottom edge, <width> characters, with titles and junctions set into
# it at their positions (in order, none on a corner), into AIF_TUI_OUT.
aif_tui_border() {
  local LC_CTYPE="${AIF_TUI_UTF8:-${LC_CTYPE:-}}"
  local width="$1" tone="$2" left="$3" right="$4" x=1 out pos t text n c ct
  shift 4
  c="AIF_TUI_C_$tone"
  ct="${!c-}"
  out="$ct$left"
  while [ $# -ge 3 ]; do
    pos="$1"
    t="$2"
    text="$3"
    shift 3
    n=${#text}
    [ "$pos" -ge "$x" ] && [ $((pos + n)) -le $((width - 1)) ] || continue
    aif_tui_rep $((pos - x)) "$AIF_TUI_G_h"
    c="AIF_TUI_C_$t"
    out="$out$AIF_TUI_OUT$AIF_TUI_C_reset${!c-}$text$AIF_TUI_C_reset$ct"
    x=$((pos + n))
  done
  aif_tui_rep $((width - 1 - x)) "$AIF_TUI_G_h"
  AIF_TUI_OUT="$out$AIF_TUI_OUT$right$AIF_TUI_C_reset"
}

# aif_tui_ago <seconds> — "45s", "31m", "2h05", into AIF_TUI_OUT.
aif_tui_ago() {
  local s="$1"
  [ "$s" -ge 0 ] 2>/dev/null || s=0
  if [ "$s" -lt 60 ]; then
    AIF_TUI_OUT="${s}s"
  elif [ "$s" -lt 3600 ]; then
    AIF_TUI_OUT="$((s / 60))m"
  else
    AIF_TUI_OUT="$((s / 3600))h$(printf '%02d' $(((s % 3600) / 60)))"
  fi
}

# aif_tui_slot <i> — slot i's live state read into AIF_TUI_W_* (the worker
# wrote it as JSON; one jq for all of it), its progress worked out, and the
# tone of its line to the loop.
aif_tui_slot() {
  local i="$1" live result idx=0 k=0 s span start typ el pct
  live="${AIF_LS_LIVE[$i]-}"
  result="${AIF_LS_RESULT[$i]-}"
  AIF_TUI_W_title="" AIF_TUI_W_phase="" AIF_TUI_W_stage="" AIF_TUI_W_attempt="" AIF_TUI_W_amax=""
  AIF_TUI_W_model="" AIF_TUI_W_mid="" AIF_TUI_W_disp="" AIF_TUI_W_dmax="" AIF_TUI_W_tokens=""
  AIF_TUI_W_sst="" AIF_TUI_W_last="" AIF_TUI_W_ltone=""
  if [ -n "$live" ]; then
    IFS=$'\037' read -r AIF_TUI_W_title AIF_TUI_W_phase AIF_TUI_W_stage AIF_TUI_W_attempt AIF_TUI_W_amax \
      AIF_TUI_W_model AIF_TUI_W_mid AIF_TUI_W_disp AIF_TUI_W_dmax AIF_TUI_W_tokens AIF_TUI_W_sst \
      AIF_TUI_W_last AIF_TUI_W_ltone <<EOF || true
$(printf '%s' "$live" | jq -r '[.title, .phase, .stage, .attempt, .attempts_max, .model, .model_id,
    .dispatches, .dispatches_max, .tokens, .stage_started, .last, .last_tone]
  | map(if . == null then "" else tostring end) | join("\u001f")' 2>/dev/null)
EOF
  fi

  # Progress: the stage reached, then the time in it against its usual length.
  for s in $AIF_TUI_STAGES; do
    idx=$((idx + 1))
    [ "$s" != "$AIF_TUI_W_stage" ] || k=$idx
  done
  case "$result" in
    built) pct=100 ;;
    *)
      case "$AIF_TUI_W_phase" in
        claim) pct=1 ;;
        worktree) pct=3 ;;
        intake) pct=5 ;;
        report) pct=97 ;;
        run)
          case "$k" in
            1) start=5 span=25 ;;
            2) start=30 span=25 ;;
            3) start=55 span=40 ;;
            *) start=5 span=0 ;;
          esac
          typ="AIF_TUI_TYP_$AIF_TUI_W_stage"
          typ="${!typ-600}"
          [ "$typ" -gt 0 ] 2>/dev/null || typ=600
          el=$((${AIF_TUI_NOW:-0} - ${AIF_TUI_W_sst:-0}))
          [ "$el" -ge 0 ] 2>/dev/null || el=0
          el=$((el * 100 / typ))
          [ "$el" -le 90 ] || el=90
          pct=$((start + span * el / 100))
          ;;
        *) pct=0 ;;
      esac
      ;;
  esac
  # Never backwards within a stage; a replan goes back to plan, honestly.
  if [ "$k" -eq "${AIF_LS_PSTAGE[$i]:-0}" ] && [ "$pct" -lt "${AIF_LS_PCT[$i]:-0}" ]; then
    pct="${AIF_LS_PCT[$i]}"
  fi
  case "$result" in
    blocked | stopped | env) pct="${AIF_LS_PCT[$i]:-$pct}" ;;
  esac
  AIF_LS_PCT[i]="$pct"
  AIF_LS_PSTAGE[i]="$k"
  AIF_TUI_W_pct="$pct"
  AIF_TUI_W_k="$k"

  # The tone of the line to the loop, and whether it is dashed (still
  # getting ready) — the same tone the box's state line uses.
  AIF_TUI_W_dash=0
  case "$result" in
    built) AIF_TUI_W_link=green ;;
    blocked | env) AIF_TUI_W_link=red ;;
    stopped) AIF_TUI_W_link=dim ;;
    running)
      AIF_TUI_W_link=orange
      case "$AIF_TUI_W_phase" in
        claim | worktree | intake | "") AIF_TUI_W_dash=1 ;;
      esac
      ;;
    *) AIF_TUI_W_link=dim AIF_TUI_W_dash=1 ;;
  esac
}

# AIF_LS_* are the loop's, assigned in lib/cmd_work.sh.
# shellcheck disable=SC2153
# aif_tui_worker <i> <width> <side l|r> <half top|bottom> <attach> — the worker in
# slot i as a box, into AIF_TUI_BOX[0..8]: the title set into its top edge on
# its outer side, and the junction of its line to the loop at <attach>.
aif_tui_worker() {
  local i="$1" w="$2" side="$3" half="$4" at="$5" tw id title tpos sel tone stline right n glyph
  local bar_k bar s idx done_tone stat amt
  tw=$((w - 4))
  aif_tui_slot "$i"
  id="${AIF_LS_ID[$i]-}"
  tone=orangeb
  sel=""
  if [ "${AIF_TUI_SEL:-0}" = "$i" ]; then
    tone=sel
    sel="$AIF_TUI_G_sel"
  fi
  title=" ${sel}$i $AIF_TUI_G_sep ${id:-waiting} "
  [ -n "$id" ] || title=" $sel$i $AIF_TUI_G_sep a free slot "
  aif_tui_len "$title"
  tpos=2
  [ "$side" = l ] || tpos=$((w - 2 - AIF_TUI_N))
  # a line coming in from above: the junction points up
  glyph="$AIF_TUI_G_up"
  if [ "$half" = bottom ]; then
    if [ "$tpos" -lt "$at" ]; then
      aif_tui_border "$w" orange "$AIF_TUI_G_tl" "$AIF_TUI_G_tr" "$tpos" "$tone" "$title" "$at" "$AIF_TUI_W_link" "$glyph"
    else
      aif_tui_border "$w" orange "$AIF_TUI_G_tl" "$AIF_TUI_G_tr" "$at" "$AIF_TUI_W_link" "$glyph" "$tpos" "$tone" "$title"
    fi
  else
    aif_tui_border "$w" orange "$AIF_TUI_G_tl" "$AIF_TUI_G_tr" "$tpos" "$tone" "$title"
  fi
  AIF_TUI_BOX[0]="$AIF_TUI_OUT"

  # 1: the ticket's title
  if [ -z "$id" ]; then
    aif_tui_line "$tw" dim "waiting for a card"
  elif [ -n "$AIF_TUI_W_title" ]; then
    aif_tui_line "$tw" bold "$AIF_TUI_W_title"
  else
    aif_tui_line "$tw" dim "taking the card"
  fi
  AIF_TUI_BOX[1]="$AIF_TUI_OUT"

  # 2: where it is, or how it ended
  case "${AIF_LS_RESULT[$i]-}" in
    built) aif_tui_line "$tw" green "$AIF_TUI_G_ok built $AIF_TUI_G_to Review" ;;
    blocked) aif_tui_line "$tw" red "$AIF_TUI_G_no Blocked${AIF_LS_KIND[$i]:+: ${AIF_LS_KIND[$i]}}" ;;
    env) aif_tui_line "$tw" red "$AIF_TUI_G_no could not start $AIF_TUI_G_sep the machine" ;;
    stopped) aif_tui_line "$tw" dim "$AIF_TUI_G_halt stopped" ;;
    running)
      case "$AIF_TUI_W_phase" in
        run)
          stline="$AIF_TUI_W_stage"
          right=""
          [ -z "$AIF_TUI_W_attempt" ] || right="attempt $AIF_TUI_W_attempt/${AIF_TUI_W_amax:-?}"
          aif_tui_len "$AIF_TUI_G_run $stline$right"
          n=$((tw - AIF_TUI_N))
          [ "$n" -ge 1 ] || n=1
          aif_tui_rep "$n" " "
          amt=dim
          [ "${AIF_TUI_W_attempt:-1}" -le 1 ] 2>/dev/null || amt=yellow
          aif_tui_line "$tw" orange "$AIF_TUI_G_run " fg "$stline" fg "$AIF_TUI_OUT" "$amt" "$right"
          ;;
        report) aif_tui_line "$tw" orange "$AIF_TUI_G_run " fg "writing the report" ;;
        worktree) aif_tui_line "$tw" orange "$AIF_TUI_G_prep " fg "preparing its worktree" ;;
        intake) aif_tui_line "$tw" orange "$AIF_TUI_G_prep " fg "reading the ticket" ;;
        *) aif_tui_line "$tw" orange "$AIF_TUI_G_prep " fg "taking the card" ;;
      esac
      ;;
    *) aif_tui_line "$tw" dim "" ;;
  esac
  AIF_TUI_BOX[2]="$AIF_TUI_OUT"

  # 3: the model the station runs on
  if [ -n "$AIF_TUI_W_model" ]; then
    if [ -n "$AIF_TUI_W_mid" ] && [ "$AIF_TUI_W_mid" != "$AIF_TUI_W_model" ]; then
      aif_tui_line "$tw" fg "$AIF_TUI_W_model" dim " $AIF_TUI_G_to $AIF_TUI_W_mid"
    else
      aif_tui_line "$tw" fg "$AIF_TUI_W_model"
    fi
  else
    aif_tui_line "$tw" dim ""
  fi
  AIF_TUI_BOX[3]="$AIF_TUI_OUT"

  # 4: the bar
  bar_k=$((AIF_TUI_W_pct * 20 / 100))
  aif_tui_rep "$bar_k" "$AIF_TUI_G_full"
  bar="$AIF_TUI_OUT"
  aif_tui_rep $((20 - bar_k)) "$AIF_TUI_G_empty"
  if [ "$AIF_TUI_W_pct" -ge 100 ]; then
    aif_tui_line "$tw" "$AIF_TUI_W_link" "$bar" dim "$AIF_TUI_OUT" fg "  100%"
  elif [ -n "$id" ]; then
    aif_tui_line "$tw" "$AIF_TUI_W_link" "$bar" dim "$AIF_TUI_OUT" fg "  ~$AIF_TUI_W_pct%"
  else
    aif_tui_line "$tw" dim "$bar$AIF_TUI_OUT"
  fi
  AIF_TUI_BOX[4]="$AIF_TUI_OUT"

  # 5: the stations, done and to come
  set --
  idx=0
  for s in $AIF_TUI_STAGES; do
    idx=$((idx + 1))
    [ "$idx" -eq 1 ] || set -- "$@" dim " $AIF_TUI_G_next "
    if [ "${AIF_LS_RESULT[$i]-}" = built ] || { [ "$AIF_TUI_W_k" -gt 0 ] && [ "$idx" -lt "$AIF_TUI_W_k" ]; }; then
      set -- "$@" dim "$s " green "$AIF_TUI_G_ok"
    elif [ "$idx" -eq "$AIF_TUI_W_k" ]; then
      done_tone="fg"
      case "${AIF_LS_RESULT[$i]-}" in
        blocked | env) done_tone=red ;;
        stopped) done_tone=dim ;;
      esac
      set -- "$@" "$done_tone" "$s"
    else
      set -- "$@" dim "$s"
    fi
  done
  aif_tui_line "$tw" "$@"
  AIF_TUI_BOX[5]="$AIF_TUI_OUT"

  # 6: how long, how many dispatches, how many tokens out
  if [ -n "$id" ]; then
    if [ -n "${AIF_LS_END[$i]-}" ] && [ "${AIF_LS_RESULT[$i]-}" != running ]; then
      aif_tui_ago $((${AIF_LS_END[$i]} - ${AIF_LS_START[$i]:-0}))
    else
      aif_tui_ago $((${AIF_TUI_NOW:-0} - ${AIF_LS_START[$i]:-0}))
    fi
    stat="$AIF_TUI_OUT"
    [ -z "$AIF_TUI_W_dmax" ] ||
      stat="$stat $AIF_TUI_G_sep ${AIF_TUI_W_disp:-0}/$AIF_TUI_W_dmax disp $AIF_TUI_G_sep $(((${AIF_TUI_W_tokens:-0} + 500) / 1000))k out"
    aif_tui_line "$tw" dim "$stat"
  else
    aif_tui_line "$tw" dim ""
  fi
  AIF_TUI_BOX[6]="$AIF_TUI_OUT"

  # 7: the last verdict
  case "$AIF_TUI_W_ltone" in
    ok) tone=green ;;
    retry) tone=yellow ;;
    stop) tone=red ;;
    *) tone=dim ;;
  esac
  aif_tui_line "$tw" "$tone" "$AIF_TUI_W_last"
  AIF_TUI_BOX[7]="$AIF_TUI_OUT"

  # the rows between the edges
  for n in 1 2 3 4 5 6 7; do
    AIF_TUI_BOX[n]="$AIF_TUI_C_orange$AIF_TUI_G_v$AIF_TUI_C_reset ${AIF_TUI_BOX[n]} $AIF_TUI_C_orange$AIF_TUI_G_v$AIF_TUI_C_reset"
  done

  if [ "$half" = top ]; then
    aif_tui_border "$w" orange "$AIF_TUI_G_bl" "$AIF_TUI_G_br" "$at" "$AIF_TUI_W_link" "$AIF_TUI_G_down"
  else
    aif_tui_border "$w" orange "$AIF_TUI_G_bl" "$AIF_TUI_G_br"
  fi
  AIF_TUI_BOX[8]="$AIF_TUI_OUT"
}

# aif_tui_center_lines <width> — the loop's own six lines, into AIF_TUI_CL[1..6].
aif_tui_center_lines() {
  local tw="$1" running=0 i ready="" n=0 id
  for i in $(seq 1 "${AIF_TUI_PARALLEL:-1}"); do
    [ "${AIF_LS_RESULT[$i]-}" != running ] || running=$((running + 1))
  done
  aif_tui_line "$tw" blueb "aif work --loop"
  AIF_TUI_CL[1]="$AIF_TUI_OUT"
  aif_tui_ago $((${AIF_TUI_NOW:-0} - ${AIF_TUI_STARTED:-0}))
  aif_tui_line "$tw" fg "running " blueb "$running/${AIF_TUI_PARALLEL:-1}" dim " $AIF_TUI_G_sep $AIF_TUI_OUT"
  AIF_TUI_CL[2]="$AIF_TUI_OUT"
  for id in ${AIF_TUI_READY:-}; do
    n=$((n + 1))
    [ "$n" -gt 2 ] || ready="${ready:+$ready, }$id"
  done
  [ "$n" -le 2 ] || ready="$ready $AIF_TUI_G_more"
  if [ "$n" -gt 0 ]; then
    aif_tui_line "$tw" fg "Ready $n $AIF_TUI_G_to " dim "$ready"
  else
    aif_tui_line "$tw" dim "Ready: nothing left to take"
  fi
  AIF_TUI_CL[3]="$AIF_TUI_OUT"
  set -- green "$AIF_TUI_G_ok ${AIF_TUI_BUILT:-0}" fg " Review   " red "$AIF_TUI_G_no ${AIF_TUI_BLOCKED:-0}" fg " Blocked"
  [ "${AIF_TUI_STOPPED:-0}" -eq 0 ] || set -- "$@" fg "   " dim "$AIF_TUI_G_halt ${AIF_TUI_STOPPED} stopped"
  aif_tui_line "$tw" "$@"
  AIF_TUI_CL[4]="$AIF_TUI_OUT"
  aif_tui_line "$tw" dim "load ${AIF_TUI_LOAD:-?} $AIF_TUI_G_sep ${AIF_TUI_DISK:-?}"
  AIF_TUI_CL[5]="$AIF_TUI_OUT"
  aif_tui_line "$tw" "${AIF_TUI_STATUS_TONE:-dim}" "${AIF_TUI_STATUS:-Ctrl-C: no new cards}"
  AIF_TUI_CL[6]="$AIF_TUI_OUT"
}

# aif_tui_tail <cols> — the bottom of the frame: the last events (or the
# selected worker's log), the keys, and what the colours mean; appended to
# AIF_TUI_FRAME.
aif_tui_tail() {
  local cols="$1" line tone at text n=0 sel_id
  AIF_TUI_FRAME="$AIF_TUI_FRAME
"
  if [ "${AIF_TUI_BOTTOM:-events}" = log ]; then
    sel_id="${AIF_LS_ID[${AIF_TUI_SEL:-1}]-}"
    aif_tui_line "$((cols - 1))" blueb " log of ${sel_id:-?}" dim " (l: back to the events)"
    AIF_TUI_FRAME="$AIF_TUI_FRAME$AIF_TUI_OUT
"
    while IFS= read -r line; do
      aif_tui_line "$((cols - 1))" dim " $line"
      AIF_TUI_FRAME="$AIF_TUI_FRAME$AIF_TUI_OUT
"
    done <<EOF
${AIF_TUI_LOG:-}
EOF
  else
    while IFS='|' read -r tone at text; do
      [ -n "$text" ] || continue
      n=$((n + 1))
      aif_tui_line "$((cols - 1))" dim " $at " "${tone:-fg}" "$text"
      AIF_TUI_FRAME="$AIF_TUI_FRAME$AIF_TUI_OUT
"
    done <<EOF
${AIF_TUI_EVENTS:-}
EOF
    while [ "$n" -lt 3 ]; do
      n=$((n + 1))
      AIF_TUI_FRAME="$AIF_TUI_FRAME
"
    done
  fi
  set -- blueb " [1-${AIF_TUI_PARALLEL:-1}]" dim " select  " blueb "[s]" dim " stop it  " blueb "[l]" dim " its log  " \
    blueb "[q]" dim " no new cards  " blueb "^C" dim " no new cards, again: stop all"
  aif_tui_line "$((cols - 1))" "$@"
  AIF_TUI_FRAME="$AIF_TUI_FRAME
$AIF_TUI_OUT
"
  aif_tui_line "$((cols - 1))" orange " $AIF_TUI_G_run" dim " running  " orange "$AIF_TUI_G_prep" dim " getting ready  " \
    green "$AIF_TUI_G_ok" dim " Review  " red "$AIF_TUI_G_no" dim " Blocked  " dim "$AIF_TUI_G_halt stopped   line colour: the worker's state"
  AIF_TUI_FRAME="$AIF_TUI_FRAME$AIF_TUI_OUT"
}

# aif_tui_wide — the frame drawn around the loop: workers 1 and 2 above it,
# 3 and 4 below, each joined to it. For up to four workers on a terminal at
# least 96 wide and tall enough to hold them.
aif_tui_wide() {
  # One column short of the terminal: a line that fills the last column leaves
  # the cursor waiting to wrap, and some terminals then wrap the next one.
  local cols=$((${AIF_TUI_COLS:-100} - 1)) n="${AIF_TUI_PARALLEL:-1}" w=34 c=32 xc lx rx cl cr r gap
  local -a L R
  xc=$(((cols - c) / 2))
  lx=$((w - 9))
  rx=$((cols - w + 8))
  cl=$((xc + 6))
  cr=$((xc + c - 7))
  gap=$((cols - 2 * w))
  AIF_TUI_FRAME=""

  # the two above
  aif_tui_worker 1 "$w" l top "$lx"
  local t1="$AIF_TUI_W_link" d1="$AIF_TUI_W_dash" t2="" d2=0
  for r in 0 1 2 3 4 5 6 7 8; do L[r]="${AIF_TUI_BOX[r]}"; done
  if [ "$n" -ge 2 ]; then
    aif_tui_worker 2 "$w" r top 8
    t2="$AIF_TUI_W_link" d2="$AIF_TUI_W_dash"
    for r in 0 1 2 3 4 5 6 7 8; do R[r]="${AIF_TUI_BOX[r]}"; done
  fi
  for r in 0 1 2 3 4 5 6 7 8; do
    if [ "$n" -ge 2 ]; then
      aif_tui_rep "$gap" " "
      AIF_TUI_FRAME="$AIF_TUI_FRAME${L[r]}$AIF_TUI_OUT${R[r]}
"
    else
      AIF_TUI_FRAME="$AIF_TUI_FRAME${L[r]}
"
    fi
  done
  aif_tui_links_down "$lx" "$cl" "$cr" "$rx" "$t1" "$d1" "$t2" "$d2" "$n"

  # the loop
  aif_tui_center_lines $((c - 4))
  set --
  set -- "$((cl - xc))" "$t1" "$AIF_TUI_G_up"
  [ "$n" -lt 2 ] || set -- "$@" "$((cr - xc))" "$t2" "$AIF_TUI_G_up"
  aif_tui_border "$c" blue "$AIF_TUI_G_tl" "$AIF_TUI_G_tr" "$@"
  local top="$AIF_TUI_OUT"
  aif_tui_rep "$xc" " "
  local pad="$AIF_TUI_OUT"
  AIF_TUI_FRAME="$AIF_TUI_FRAME$pad$top
"
  for r in 1 2 3 4 5 6; do
    AIF_TUI_FRAME="$AIF_TUI_FRAME$pad$AIF_TUI_C_blue$AIF_TUI_G_v$AIF_TUI_C_reset ${AIF_TUI_CL[r]} $AIF_TUI_C_blue$AIF_TUI_G_v$AIF_TUI_C_reset
"
  done

  # the two below
  local t3="" d3=0 t4="" d4=0
  if [ "$n" -ge 3 ]; then
    aif_tui_slot 3
    t3="$AIF_TUI_W_link" d3="$AIF_TUI_W_dash"
    if [ "$n" -ge 4 ]; then
      aif_tui_slot 4
      t4="$AIF_TUI_W_link" d4="$AIF_TUI_W_dash"
    fi
  fi
  set --
  [ "$n" -lt 3 ] || set -- "$((cl - xc))" "$t3" "$AIF_TUI_G_down"
  [ "$n" -lt 4 ] || set -- "$@" "$((cr - xc))" "$t4" "$AIF_TUI_G_down"
  aif_tui_border "$c" blue "$AIF_TUI_G_bl" "$AIF_TUI_G_br" ${1+"$@"}
  AIF_TUI_FRAME="$AIF_TUI_FRAME$pad$AIF_TUI_OUT
"
  if [ "$n" -ge 3 ]; then
    aif_tui_links_up "$lx" "$cl" "$cr" "$rx" "$t3" "$d3" "$t4" "$d4" "$n"
    aif_tui_worker 3 "$w" l bottom "$lx"
    for r in 0 1 2 3 4 5 6 7 8; do L[r]="${AIF_TUI_BOX[r]}"; done
    if [ "$n" -ge 4 ]; then
      aif_tui_worker 4 "$w" r bottom 8
      for r in 0 1 2 3 4 5 6 7 8; do R[r]="${AIF_TUI_BOX[r]}"; done
    fi
    for r in 0 1 2 3 4 5 6 7 8; do
      if [ "$n" -ge 4 ]; then
        aif_tui_rep "$gap" " "
        AIF_TUI_FRAME="$AIF_TUI_FRAME${L[r]}$AIF_TUI_OUT${R[r]}
"
      else
        AIF_TUI_FRAME="$AIF_TUI_FRAME${L[r]}
"
      fi
    done
  fi
  aif_tui_tail "$cols"
}

# aif_tui_links_down / aif_tui_links_up <lx> <cl> <cr> <rx> <tone-l> <dash-l>
# <tone-r> <dash-r> <n> — the two rows joining the workers above the loop to
# its top edge, or its bottom edge to the workers below.
aif_tui_links_down() {
  local lx="$1" cl="$2" cr="$3" rx="$4" tl="$5" dl="$6" tr="$7" dr="$8" n="$9"
  local vl hl vr hr row c
  vl="$AIF_TUI_G_v" hl="$AIF_TUI_G_h" vr="$AIF_TUI_G_v" hr="$AIF_TUI_G_h"
  [ "$dl" != 1 ] || vl="$AIF_TUI_G_dv" hl="$AIF_TUI_G_dh"
  [ "$dr" != 1 ] || vr="$AIF_TUI_G_dv" hr="$AIF_TUI_G_dh"
  # the vertical row
  aif_tui_rep "$lx" " "
  c="AIF_TUI_C_$tl"
  row="$AIF_TUI_OUT${!c-}$vl$AIF_TUI_C_reset"
  if [ "$n" -ge 2 ]; then
    aif_tui_rep $((rx - lx - 1)) " "
    c="AIF_TUI_C_$tr"
    row="$row$AIF_TUI_OUT${!c-}$vr$AIF_TUI_C_reset"
  fi
  AIF_TUI_FRAME="$AIF_TUI_FRAME$row
"
  # the turning row
  aif_tui_rep "$lx" " "
  row="$AIF_TUI_OUT"
  c="AIF_TUI_C_$tl"
  aif_tui_rep $((cl - lx - 1)) "$hl"
  row="$row${!c-}$AIF_TUI_G_bl$AIF_TUI_OUT$AIF_TUI_G_tr$AIF_TUI_C_reset"
  if [ "$n" -ge 2 ]; then
    aif_tui_rep $((cr - cl - 1)) " "
    row="$row$AIF_TUI_OUT"
    c="AIF_TUI_C_$tr"
    aif_tui_rep $((rx - cr - 1)) "$hr"
    row="$row${!c-}$AIF_TUI_G_tl$AIF_TUI_OUT$AIF_TUI_G_br$AIF_TUI_C_reset"
  fi
  AIF_TUI_FRAME="$AIF_TUI_FRAME$row
"
}

aif_tui_links_up() {
  local lx="$1" cl="$2" cr="$3" rx="$4" tl="$5" dl="$6" tr="$7" dr="$8" n="$9"
  local vl hl vr hr row c
  vl="$AIF_TUI_G_v" hl="$AIF_TUI_G_h" vr="$AIF_TUI_G_v" hr="$AIF_TUI_G_h"
  [ "$dl" != 1 ] || vl="$AIF_TUI_G_dv" hl="$AIF_TUI_G_dh"
  [ "$dr" != 1 ] || vr="$AIF_TUI_G_dv" hr="$AIF_TUI_G_dh"
  # the turning row
  aif_tui_rep "$lx" " "
  row="$AIF_TUI_OUT"
  c="AIF_TUI_C_$tl"
  aif_tui_rep $((cl - lx - 1)) "$hl"
  row="$row${!c-}$AIF_TUI_G_tl$AIF_TUI_OUT$AIF_TUI_G_br$AIF_TUI_C_reset"
  if [ "$n" -ge 4 ]; then
    aif_tui_rep $((cr - cl - 1)) " "
    row="$row$AIF_TUI_OUT"
    c="AIF_TUI_C_$tr"
    aif_tui_rep $((rx - cr - 1)) "$hr"
    row="$row${!c-}$AIF_TUI_G_bl$AIF_TUI_OUT$AIF_TUI_G_tr$AIF_TUI_C_reset"
  fi
  AIF_TUI_FRAME="$AIF_TUI_FRAME$row
"
  # the vertical row
  aif_tui_rep "$lx" " "
  c="AIF_TUI_C_$tl"
  row="$AIF_TUI_OUT${!c-}$vl$AIF_TUI_C_reset"
  if [ "$n" -ge 4 ]; then
    aif_tui_rep $((rx - lx - 1)) " "
    c="AIF_TUI_C_$tr"
    row="$row$AIF_TUI_OUT${!c-}$vr$AIF_TUI_C_reset"
  fi
  AIF_TUI_FRAME="$AIF_TUI_FRAME$row
"
}

# aif_tui_compact — the same, as a list: the loop on one line, each worker on
# three. For a narrow or a short terminal, or more than four workers.
aif_tui_compact() {
  local cols="${AIF_TUI_COLS:-80}" i n="${AIF_TUI_PARALLEL:-1}" tone sel id state
  AIF_TUI_FRAME=""
  aif_tui_ago $((${AIF_TUI_NOW:-0} - ${AIF_TUI_STARTED:-0}))
  aif_tui_line "$((cols - 1))" blueb "aif work --loop" dim " $AIF_TUI_G_sep $AIF_TUI_OUT $AIF_TUI_G_sep " \
    green "$AIF_TUI_G_ok ${AIF_TUI_BUILT:-0}" dim " " red "$AIF_TUI_G_no ${AIF_TUI_BLOCKED:-0}" \
    dim " $AIF_TUI_G_sep load ${AIF_TUI_LOAD:-?} $AIF_TUI_G_sep ${AIF_TUI_STATUS:-Ctrl-C: no new cards}"
  AIF_TUI_FRAME="$AIF_TUI_OUT
"
  for i in $(seq 1 "$n"); do
    aif_tui_slot "$i"
    id="${AIF_LS_ID[$i]-}"
    tone=orangeb
    sel=" "
    if [ "${AIF_TUI_SEL:-0}" = "$i" ]; then
      tone=sel
      sel="$AIF_TUI_G_sel"
    fi
    case "${AIF_LS_RESULT[$i]-}" in
      built) state="$AIF_TUI_G_ok built $AIF_TUI_G_to Review" ;;
      blocked) state="$AIF_TUI_G_no Blocked${AIF_LS_KIND[$i]:+: ${AIF_LS_KIND[$i]}}" ;;
      env) state="$AIF_TUI_G_no could not start" ;;
      stopped) state="$AIF_TUI_G_halt stopped" ;;
      running)
        state="$AIF_TUI_G_run ${AIF_TUI_W_stage:-${AIF_TUI_W_phase:-starting}}"
        [ -z "$AIF_TUI_W_attempt" ] || state="$state $AIF_TUI_W_attempt/${AIF_TUI_W_amax:-?}"
        [ -z "$AIF_TUI_W_model" ] || state="$state $AIF_TUI_G_sep $AIF_TUI_W_model"
        ;;
      *) state="waiting for a card" ;;
    esac
    AIF_TUI_FRAME="$AIF_TUI_FRAME
"
    aif_tui_line "$((cols - 1))" "$tone" "$sel$i ${id:-$AIF_TUI_G_sep}" bold " ${AIF_TUI_W_title:-}" \
      dim "  " "$AIF_TUI_W_link" "$state"
    AIF_TUI_FRAME="$AIF_TUI_FRAME$AIF_TUI_OUT
"
    aif_tui_rep $((AIF_TUI_W_pct * 20 / 100)) "$AIF_TUI_G_full"
    local bar="$AIF_TUI_OUT"
    aif_tui_rep $((20 - AIF_TUI_W_pct * 20 / 100)) "$AIF_TUI_G_empty"
    aif_tui_line "$((cols - 1))" fg "   " "$AIF_TUI_W_link" "$bar" dim "$AIF_TUI_OUT" fg " ~$AIF_TUI_W_pct%" \
      dim "  ${AIF_TUI_W_disp:-0}/${AIF_TUI_W_dmax:-?} disp $AIF_TUI_G_sep $(((${AIF_TUI_W_tokens:-0} + 500) / 1000))k out"
    AIF_TUI_FRAME="$AIF_TUI_FRAME$AIF_TUI_OUT
"
    case "$AIF_TUI_W_ltone" in
      ok) tone=green ;;
      retry) tone=yellow ;;
      stop) tone=red ;;
      *) tone=dim ;;
    esac
    aif_tui_line "$((cols - 1))" fg "   " "$tone" "$AIF_TUI_W_last"
    AIF_TUI_FRAME="$AIF_TUI_FRAME$AIF_TUI_OUT
"
  done
  aif_tui_tail "$cols"
}

# aif_tui_frame — the frame for this terminal, into AIF_TUI_FRAME: drawn around
# the loop where it fits, as a list where it does not.
aif_tui_frame() {
  local need=26
  [ "${AIF_TUI_PARALLEL:-1}" -le 2 ] || need=37
  if [ "${AIF_TUI_PARALLEL:-1}" -le 4 ] && [ "${AIF_TUI_COLS:-80}" -ge 96 ] && [ "${AIF_TUI_ROWS:-24}" -ge "$need" ]; then
    aif_tui_wide
  else
    aif_tui_compact
  fi
}
