#!/usr/bin/env bash
#
# Shared output helpers and small predicates.
# Sourced by bin/aif; not meant to be executed directly.

# Colour only when stdout is a terminal and NO_COLOR is unset.
# https://no-color.org/
#
# Some of these are consumed only by the modules that source this file, which
# is invisible to a linter reading each file on its own.
# shellcheck disable=SC2034
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  AIF_C_RESET=$'\033[0m'
  AIF_C_BOLD=$'\033[1m'
  AIF_C_DIM=$'\033[2m'
  AIF_C_RED=$'\033[31m'
  AIF_C_GREEN=$'\033[32m'
  AIF_C_YELLOW=$'\033[33m'
else
  AIF_C_RESET=''
  AIF_C_BOLD=''
  AIF_C_DIM=''
  AIF_C_RED=''
  AIF_C_GREEN=''
  AIF_C_YELLOW=''
fi

# Traps are per-process, not per-function: a bare `trap -` anywhere in a
# library takes the CALLER's handler with it. That is not hypothetical — the
# worker's interrupt handler was dead from the first ledger write onwards, and
# had been since the day it was written (docs/DEFECTS.md 3.1).
#
# So a command that needs a handler to outlive the libraries it calls arms it
# here, and a library that needs a trap of its own restores it here afterwards
# rather than clearing the slate.
# shellcheck disable=SC2034  # read by the modules that source this file
AIF_TRAP_ARMED=""

# aif_trap_arm <handler> — run <handler> on EXIT, INT, TERM and HUP, with the
# name of the one that fired as its argument. A handler that ends the process
# needs it: an interrupt ends in 130, a TERM in 143 and a hang-up in 129, while
# an exit — an aif_die, a command failing under set -e — keeps its own code.
#
# HUP is a closed terminal: the window goes, the shell in it hangs up on its
# jobs, and until 0.15.0 nothing in aif caught it. The loop and the land died
# of it where they stood — a land between its merge and its verdict left the
# merge on the branch — while the loop's workers, each in a process group of
# its own, were no job of that shell, got nothing, and went on building and
# writing with nobody left to read them (docs/AUTOPILOT-RESEARCH.md §6.11,
# verifications 2, 5 and 6; docs/DEFECTS.md 14.8). Trapped, the one process
# that does get the hang-up can settle its card, undo its merge, or tell the
# runs under it to stop.
aif_trap_arm() {
  AIF_TRAP_ARMED="$1"
  aif_trap_restore
}

# aif_trap_restore — put back whatever was armed, or clear if nothing was.
aif_trap_restore() {
  local sig
  if [ -z "${AIF_TRAP_ARMED:-}" ]; then
    trap - EXIT INT TERM HUP
    return 0
  fi
  for sig in EXIT INT TERM HUP; do
    # shellcheck disable=SC2064  # the handler IS the argument; expanding it now
    trap "$AIF_TRAP_ARMED $sig" "$sig"
  done
}

# aif_trap_disarm — the command that armed a handler takes it back, once what
# it guarded has settled. Only that command: a library restores.
aif_trap_disarm() {
  AIF_TRAP_ARMED=""
  aif_trap_restore
}

# The last error said, kept for a handler that has to say why a command
# stopped after the fact: the worker's exit handler puts it on the card, where
# the human looks, instead of leaving it in the scrollback of whoever ran it.
# shellcheck disable=SC2034  # read by lib/cmd_work.sh
AIF_LAST_ERR=""

aif_err() {
  AIF_LAST_ERR="$*"
  printf '%serror:%s %s\n' "$AIF_C_RED" "$AIF_C_RESET" "$*" >&2
}

aif_warn() {
  printf '%swarn:%s %s\n' "$AIF_C_YELLOW" "$AIF_C_RESET" "$*" >&2
}

aif_die() {
  aif_err "$*"
  exit 1
}

# aif_have <command> — true if the command is on PATH.
aif_have() {
  command -v "$1" >/dev/null 2>&1
}

# aif_git_own <dir> <git args…> — git in <dir>, run on aif's own behalf, with
# none of the project's hooks: `git -C <dir> -c core.hooksPath=/dev/null …`.
#
# The worker's commits on aif/<ID> — intake, each admitted station, a repair,
# the record, the report, a restart, a rebuild, the sync's merge — are
# bookkeeping on a disposable branch, and they ran the project's hooks: a
# pre-commit that fails (husky, lint-staged) stopped a run at `aif _commit` as
# "the tool, not the station" and silently skipped the commits made with
# `|| true`, and one that rewrites the files it is given changed frozen tests
# after their hashes were taken (docs/DEFECTS.md 13.11). `--no-verify` is not
# enough: it skips pre-commit and commit-msg only, and the worktree and
# checkout calls run post-checkout — one that exits 7 makes `git worktree add`
# exit 7 after the checkout is made, and `git checkout --ours -- <path>` the
# same, so the sync took its own settlement for a conflict left (probed:
# docs/FINDINGS.md #30). With the hooks path pointed where no hook can be,
# none runs — pre-commit, prepare-commit-msg, commit-msg, post-commit,
# post-checkout, post-merge, reference-transaction, post-index-change. The
# land's own commit keeps them: that is the commit the project's hooks are for
# (lib/cmd_land.sh). A read (rev-parse, show, diff, log) runs no hook and
# needs none of this.
aif_git_own() {
  local dir="$1"
  shift
  git -C "$dir" -c core.hooksPath=/dev/null "$@"
}

# aif_host_short — this machine's name, as aif writes it wherever a claim says
# where: the worker's `taken:` comment, the loop's and the shift's locks, what
# the shift reads off a card to tell its own claims from another machine's.
#
# One spelling everywhere, because they are compared — the claim exists to be
# read by another process deciding whose card it is (docs/DEFECTS.md 14.4) —
# and on a Mac `hostname` says `name.local` where `hostname -s` says `name`: a
# claim written with one and read with the other is another machine's.
# `hostname -s` with its fallbacks, whitespace taken out; `?` when there is
# nothing to say.
aif_host_short() {
  local h
  h="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf '%s' "${HOSTNAME:-?}")"
  h="$(printf '%s' "$h" | tr -d '[:space:]')"
  printf '%s' "${h:-?}"
}

# aif_clone_id <root> — the name of this checkout beside its host's in a claim
# (`taken: <host>:<clone> pid …`): six hex characters, made once for the main
# checkout and kept in its .aif/state/, in a file named for the checkout's
# physical path.
#
# The host alone named the machine and not the checkout: two clones of one
# project on one machine — and two machines with one short name, as two Macs
# left at their default names are — wrote the same `taken: <host>`, and each
# read the other's claim as its own: the check skipped nothing, the race found
# no rival, and both built the card (docs/DEFECTS.md 14.4; probed, 2 of 2
# built twice). A random name tells apart what a path cannot — one path on
# two machines of one name — and the file it is kept in is named for the
# path, so a copy of a checkout, .aif/state and all, names itself anew rather
# than take the original's. Every worktree and every process of the checkout
# reads the one file; the first to make it links it into place whole (`ln`
# fails on a name that exists), so two that make it at once both read the one
# that won. A checkout moved elsewhere names itself anew too — a claim it
# posted before the move reads as another checkout's until its worker's wall
# clock has passed. A state directory that cannot be written falls back on
# the path's own checksum: stable, and blind to one path on two machines.
aif_clone_id() {
  local main key f id tmp
  main="$(aif_main_root "$1")"
  key="$(printf '%s' "$main" | cksum | cut -d' ' -f1)"
  f="$main/.aif/state/clone-$key"
  id="$(sed -n 1p "$f" 2>/dev/null)" || id=""
  if ! _aif_clone_ok "$id"; then
    id="$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" || id=""
    if _aif_clone_ok "$id" && [ -d "$main/.aif" ] && mkdir -p "$main/.aif/state" 2>/dev/null &&
      tmp="$(mktemp "$main/.aif/state/.clone-XXXXXX" 2>/dev/null)"; then
      { printf '%s\n' "$id" >"$tmp" && ln "$tmp" "$f"; } 2>/dev/null || true
      rm -f "$tmp"
    fi
    id="$(sed -n 1p "$f" 2>/dev/null)" || id=""
    _aif_clone_ok "$id" || id="$(printf '%06x' "$((key % 16777216))")"
  fi
  printf '%s' "$id"
}

# _aif_clone_ok <id> — rc 0 for a clone id as aif_clone_id makes one.
_aif_clone_ok() {
  case "$1" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) return 0 ;;
  esac
  return 1
}

# aif_meta_json <file> — the JSON out of the FIRST aif:meta HTML comment.
#
# Only the first: a station prompt legitimately contains an example aif:meta
# block in its body, and a model's output may echo the format. Matching every
# block would concatenate them into invalid JSON.
#
# The same block the gates read (their copy lives in .aif/gates/_lib.sh, which
# cannot source this file — it runs in CI without aif). Keep the two awk
# programs identical.
aif_meta_json() {
  # The CR is stripped first: a ticket edited in a browser can come back with
  # \r\n, and `<!-- aif:meta\r` matches nothing (docs/DEFECTS.md 3.10).
  awk '
    { sub(/\r$/, "") }
    /^<!-- aif:meta$/ && !seen { inblock = 1; seen = 1; next }
    inblock && /^-->$/         { inblock = 0; next }
    inblock                    { print }
  ' "$1"
}

# aif_meta_body <file> — everything after the aif:meta comment closes.
#
# For station files, the meta block carries the config and the body is the
# system prompt.
aif_meta_body() {
  awk 'body { print } /^-->$/ { body = 1 }' "$1"
}

# aif_meta_replace <file> <json> — rewrite the aif:meta block in place.
#
# How `aif _record` stamps a binding into an artifact a model wrote: the model
# owns the content, the tool owns the provenance, and neither has to trust the
# other to copy 64 hex characters correctly (see lib/cmd_record.sh).
#
# The JSON is re-serialised by jq rather than patched textually — a regex over
# someone else's JSON is how a working artifact becomes an unparseable one.
aif_meta_replace() {
  local file="$1" json="$2" tmp
  tmp="$(aif_tmpfile "$file")"
  # Beside the artifact, which lives under tasks/ — where scope reads a stray
  # file as an implementation editing the pipeline's record: it goes with a
  # write that failed (docs/DEFECTS.md 13.12).
  if ! {
    {
      printf '<!-- aif:meta\n'
      printf '%s' "$json" | jq .
      printf -- '-->\n'
      aif_meta_body "$file"
    } >"$tmp" && mv "$tmp" "$file"
  }; then
    rm -f "$tmp"
    return 1
  fi
}

# aif_meta_get <file> <key> [default] — read one KEY=VALUE line.
#
# Parsed, never sourced. Sets and evals are the things you eventually accept
# from other people, and sourcing one executes it.
aif_meta_get() {
  local file="$1" key="$2" default="${3:-}"
  local line
  line="$(grep -E "^${key}=" "$file" 2>/dev/null | head -1)" || true
  if [ -z "$line" ]; then
    printf '%s' "$default"
    return 0
  fi
  printf '%s' "${line#*=}"
}

# aif_ok <label> / aif_no <label> — status markers for report output.
# The marker carries the colour so that %-Ns padding elsewhere stays aligned;
# escape sequences inside a padded field would break the column width.
aif_ok() {
  printf '%s✓%s' "$AIF_C_GREEN" "$AIF_C_RESET"
}

aif_no() {
  printf '%s✗%s' "$AIF_C_DIM" "$AIF_C_RESET"
}
