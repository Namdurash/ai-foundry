#!/usr/bin/env bash
#
# `aif secret` — store a token where a model never sees it.
# Sourced by bin/aif; not meant to be executed directly.
#
# `set` reads the value with echo off, from the terminal the human is sitting
# at. It refuses a value on the command line — that lands in shell history —
# and it refuses a pipe unless --stdin says the caller knows what a pipe means
# here (CI, a test). There is no `get`: the CLI says whether a secret exists,
# never what it is. See lib/secret.sh.

_aif_secret_usage() {
  cat <<EOF
usage: aif secret set <NAME> [--stdin]
       aif secret check <NAME>
       aif secret rm <NAME>
       aif secret list

  set     read the value with echo off and store it — in the macOS keychain
          when there is one, else in a 0600 file under ~/.config/aif/secrets/.
          --stdin reads one line from stdin instead (for CI; never from a chat)
  check   exit 0 if NAME is set (environment, keychain or file), 1 if not
  rm      forget it
  list    the names stored here — never the values

A skill never asks you for a token. It prints this command; you run it in your
own terminal. NAME is an environment-variable name: TRELLO_TOKEN, TRELLO_KEY.
Exporting the same name in your shell overrides the store.
EOF
}

aif_cmd_secret() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift

  case "$sub" in
    set)
      local name="${1:-}" from_stdin=0 value=""
      [ -n "$name" ] || aif_die "usage: aif secret set <NAME> [--stdin]"
      shift
      while [ $# -gt 0 ]; do
        case "$1" in
          --stdin) from_stdin=1 ;;
          -*) aif_die "unknown option: $1" ;;
          *) aif_die "refusing a value on the command line — it would land in your shell history. Run 'aif secret set $name' and type it, or pipe it with --stdin." ;;
        esac
        shift
      done
      aif_secret_name_ok "$name" || aif_die "not a secret name: $name (letters, digits, underscores; starts with a letter)"
      if [ "$from_stdin" -eq 1 ]; then
        IFS= read -r value || true
      else
        [ -t 0 ] || aif_die "stdin is not a terminal — pass --stdin if you really mean to pipe the value in"
        printf '%s (echo off): ' "$name" >&2
        # -s: no echo. The trailing newline the terminal did not print.
        IFS= read -r -s value || true
        printf '\n' >&2
      fi
      value="${value%$'\r'}"
      aif_secret_set "$name" "$value"
      printf '%sstored%s %s in the %s\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$name" "$(aif_secret_backend)"
      ;;
    check)
      local name="${1:-}" where
      [ -n "$name" ] || aif_die "usage: aif secret check <NAME>"
      where="$(aif_secret_where "$name")"
      if [ -n "$where" ]; then
        printf '%s✓%s %s is set (%s)\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$name" "$where"
      else
        printf '%s✗%s %s is not set — run: aif secret set %s\n' "$AIF_C_DIM" "$AIF_C_RESET" "$name" "$name"
        return 1
      fi
      ;;
    rm)
      local name="${1:-}"
      [ -n "$name" ] || aif_die "usage: aif secret rm <NAME>"
      aif_secret_rm "$name"
      printf '%sremoved%s %s\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$name"
      ;;
    list)
      printf '%s' "$(aif_secret_list)" | sed '/^$/d'
      printf '\n' 2>/dev/null
      ;;
    -h | --help | "")
      _aif_secret_usage
      ;;
    *)
      aif_die "unknown subcommand: $sub (try: aif secret --help)"
      ;;
  esac
}
