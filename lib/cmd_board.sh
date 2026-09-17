#!/usr/bin/env bash
#
# `aif board` — the board, from the command line. Sourced by bin/aif; not meant
# to be executed directly. The operations live in lib/board.sh; this is the
# argument parsing and the rendering.

_aif_board_usage() {
  cat <<EOF
usage: aif board <operation> [args]

  next-ready                 the ticket at the top of Ready, or nothing
  pull <ID>                  the card's text → tasks/<ID>/ticket.md (trello)
  move <ID> <column> [--top] put the card in a column; --top puts it first
  comment <ID> <file>        post the file's text as a comment (the report)
  create <ticket.md> [--column ready]
                             a card for the ticket (in Backlog unless told);
                             an existing card's text is brought up to date
  status [--json]            every card, by column
  show <ID> [--json]         one card, with its comments
  label <ID> <label>         add a label (created on the board if new)
  check                      is the board reachable, as configured?
  init local | init trello --board <id or url> [--create-lists]
                             write the board block in .aif/project.json

Columns: $AIF_BOARD_COLUMNS
The board is the coupling between the analyst, the worker and the project
manager; every state transition goes through here, so a card is never quietly
somewhere else than the work is.
EOF
}

_aif_board_render_status() {
  jq -r '
    if length == 0 then "  (no cards)" else
    ( "  column        ticket       title", "  ------        ------       -----",
      ( .[] | "  " + (.column + "              ")[0:14]
            + (.ticket + "             ")[0:13]
            + (.title // "")
            + (if ((.labels // []) | length) > 0 then "  [" + (.labels | join(", ")) + "]" else "" end) ) ) end'
}

aif_cmd_board() {
  local op="${1:-}"
  [ $# -gt 0 ] && shift

  local root
  root="$(aif_require_project)"

  case "$op" in
    next-ready)
      aif_board_next_ready "$root"
      ;;
    pull)
      [ -n "${1:-}" ] || aif_die "usage: aif board pull <ID>"
      aif_board_pull "$root" "$1"
      ;;
    move)
      local id="${1:-}" col="${2:-}" where=""
      [ -n "$id" ] && [ -n "$col" ] || aif_die "usage: aif board move <ID> <column> [--top]"
      shift 2
      while [ $# -gt 0 ]; do
        case "$1" in
          --top) where="top" ;;
          --bottom) where="bottom" ;;
          *) aif_die "unknown option: $1" ;;
        esac
        shift
      done
      local canon
      canon="$(aif_board_column "$col")"
      [ -n "$canon" ] || aif_die "unknown column: $col (one of: $AIF_BOARD_COLUMNS)"
      aif_board_move "$root" "$id" "$canon" "$where"
      ;;
    comment)
      [ -n "${1:-}" ] && [ -n "${2:-}" ] || aif_die "usage: aif board comment <ID> <file>"
      [ -f "$2" ] || aif_die "no such file: $2"
      aif_board_comment "$root" "$1" "$2"
      ;;
    create)
      local ticket="${1:-}" col="backlog"
      [ -n "$ticket" ] || aif_die "usage: aif board create <ticket.md> [--column <column>]"
      [ -f "$ticket" ] || aif_die "no such file: $ticket"
      shift
      while [ $# -gt 0 ]; do
        case "$1" in
          --column)
            shift
            col="$(aif_board_column "${1:-}")"
            [ -n "$col" ] || aif_die "unknown column: ${1:-} (one of: $AIF_BOARD_COLUMNS)"
            ;;
          *) aif_die "unknown option: $1" ;;
        esac
        shift
      done
      aif_board_create "$root" "$ticket" "$col"
      ;;
    status)
      if [ "${1:-}" = "--json" ]; then
        aif_board_status_json "$root"
      else
        printf '%sboard%s %s\n' "$AIF_C_BOLD" "$AIF_C_RESET" "$(aif_board_kind "$root")"
        aif_board_status_json "$root" | _aif_board_render_status
      fi
      ;;
    show)
      [ -n "${1:-}" ] || aif_die "usage: aif board show <ID> [--json]"
      if [ "${2:-}" = "--json" ]; then
        aif_board_show_json "$root" "$1"
      else
        aif_board_show_json "$root" "$1" | jq -r '
          "\(.ticket) — \(.title)  [\(.column)]" + (if .url then "  " + .url else "" end),
          "",
          (if (.comments | length) == 0 then "  (no comments)" else
            (.comments[] | "  " + .at + "  " + .by + ":", (.text | split("\n") | map("    " + .) | join("\n")), "") end)'
      fi
      ;;
    label)
      [ -n "${1:-}" ] && [ -n "${2:-}" ] || aif_die "usage: aif board label <ID> <label>"
      aif_board_label "$root" "$1" "$2"
      ;;
    check)
      local out rc=0
      out="$(aif_board_check "$root")" || rc=$?
      if [ "$rc" -eq 0 ]; then
        printf '%s✓%s %s\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$out"
      else
        printf '%s\n' "$out" | sed "s/^/$(printf '%s✗%s ' "$AIF_C_RED" "$AIF_C_RESET")/" >&2
      fi
      return "$rc"
      ;;
    init)
      local kind="${1:-}" board="" create=0
      [ -n "$kind" ] || aif_die "usage: aif board init local | init trello --board <id or url> [--create-lists]"
      shift
      while [ $# -gt 0 ]; do
        case "$1" in
          --board)
            shift
            board="${1:-}"
            ;;
          --create-lists) create=1 ;;
          *) aif_die "unknown option: $1" ;;
        esac
        shift
      done
      aif_board_init "$root" "$kind" "$board" "$create"
      ;;
    -h | --help | "")
      _aif_board_usage
      ;;
    *)
      aif_die "unknown operation: $op (try: aif board --help)"
      ;;
  esac
}
