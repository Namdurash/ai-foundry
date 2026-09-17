#!/usr/bin/env bash
#
# Secrets — a board token, an API key — stored where a model never sees them.
# Sourced by bin/aif; not meant to be executed directly.
#
# The rule this file exists for: a secret never passes through the model. A
# token pasted into a chat lands in a transcript on disk, next to the ledger,
# and a skill that "asked for the token" has already leaked it. So the analyst
# and the setup skill never ask for a value; they print the command below, the
# human runs it in their own terminal, and the value goes from the terminal to
# the store without a model in between:
#
#   aif secret set TRELLO_TOKEN
#
# Three places a value can live, read in this order:
#
#   1. the environment — `TRELLO_TOKEN=… aif board status` and CI both work
#      without a store at all;
#   2. the macOS keychain (`security`), the OS's own store, per user;
#   3. a 0600 file under ~/.config/aif/secrets/, for everything else.
#
# AIF_SECRETS_DIR forces the file backend at that directory. Tests use it so
# that a check never touches a developer's real keychain.
#
# Nothing here prints a value except aif_secret_get, which is a library
# function the board backend calls in-process. There is deliberately no
# `aif secret get`: the CLI can say whether a secret is set, not what it is.

# aif_secret_name_ok <name> — rc 0 iff the name is an environment-variable name.
aif_secret_name_ok() {
  printf '%s' "$1" | grep -qE '^[A-Z][A-Z0-9_]*$'
}

aif_secret_dir() {
  printf '%s' "${AIF_SECRETS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aif/secrets}"
}

# aif_secret_backend — keychain | file
aif_secret_backend() {
  if [ -n "${AIF_SECRETS_DIR:-}" ]; then
    printf 'file'
  elif [ "$(uname -s 2>/dev/null)" = "Darwin" ] && aif_have security; then
    printf 'keychain'
  else
    printf 'file'
  fi
}

# aif_secret_get <name> — the value on stdout, rc 1 if it is set nowhere.
aif_secret_get() {
  local name="$1" v=""
  aif_secret_name_ok "$name" || return 1
  eval "v=\"\${$name:-}\""
  if [ -n "$v" ]; then
    printf '%s' "$v"
    return 0
  fi
  case "$(aif_secret_backend)" in
    keychain)
      v="$(security find-generic-password -a aif -s "aif:$name" -w 2>/dev/null)" || return 1
      ;;
    file)
      [ -f "$(aif_secret_dir)/$name" ] || return 1
      v="$(cat "$(aif_secret_dir)/$name")"
      ;;
  esac
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# aif_secret_where <name> — env | keychain | file | "" (unset). For reports.
aif_secret_where() {
  local name="$1" v=""
  eval "v=\"\${$name:-}\""
  if [ -n "$v" ]; then
    printf 'env'
    return 0
  fi
  case "$(aif_secret_backend)" in
    keychain)
      security find-generic-password -a aif -s "aif:$name" >/dev/null 2>&1 && printf 'keychain'
      ;;
    file)
      [ -s "$(aif_secret_dir)/$name" ] && printf 'file'
      ;;
  esac
  return 0
}

# aif_secret_set <name> <value>
aif_secret_set() {
  local name="$1" value="$2" dir
  aif_secret_name_ok "$name" || aif_die "not a secret name: $name (letters, digits, underscores; starts with a letter)"
  [ -n "$value" ] || aif_die "refusing to store an empty value for $name"
  case "$(aif_secret_backend)" in
    keychain)
      # -U updates in place; without it a second `set` fails on the duplicate.
      security add-generic-password -U -a aif -s "aif:$name" -w "$value" >/dev/null 2>&1 ||
        aif_die "the keychain refused to store $name"
      ;;
    file)
      dir="$(aif_secret_dir)"
      (umask 077 && mkdir -p "$dir" && printf '%s' "$value" >"$dir/$name.tmp" && mv "$dir/$name.tmp" "$dir/$name") ||
        aif_die "could not write $dir/$name"
      chmod 600 "$dir/$name" 2>/dev/null || true
      ;;
  esac
}

# aif_secret_rm <name>
aif_secret_rm() {
  local name="$1"
  aif_secret_name_ok "$name" || aif_die "not a secret name: $name"
  case "$(aif_secret_backend)" in
    keychain) security delete-generic-password -a aif -s "aif:$name" >/dev/null 2>&1 || true ;;
    file) rm -f "$(aif_secret_dir)/$name" ;;
  esac
}

# aif_secret_list — the names this backend holds, one per line. Never values.
aif_secret_list() {
  case "$(aif_secret_backend)" in
    keychain)
      # dump-keychain is the only enumeration the CLI offers; the service
      # attribute carries our prefix.
      security dump-keychain 2>/dev/null |
        grep -oE '"svce"<blob>="aif:[A-Z0-9_]+"' |
        sed 's/.*="aif://; s/"$//' | sort -u
      ;;
    file)
      [ -d "$(aif_secret_dir)" ] || return 0
      find "$(aif_secret_dir)" -maxdepth 1 -type f ! -name '*.tmp' -exec basename {} \; 2>/dev/null | sort
      ;;
  esac
}
