#!/usr/bin/env bash
#
# Writing into files that belong to the user, without destroying them.
# Sourced by bin/aif; not meant to be executed directly.

# The markdown markers are consumed by cmd_init, which a linter reading this
# file on its own cannot see.
# shellcheck disable=SC2034
AIF_MARK_BEGIN_MD='<!-- aif:begin — managed by ai-foundry; edits inside are overwritten -->'
AIF_MARK_END_MD='<!-- aif:end -->'
AIF_MARK_BEGIN_HASH='# aif:begin — managed by ai-foundry; edits inside are overwritten'
AIF_MARK_END_HASH='# aif:end'

# aif_write_file <dest> — content on stdin, written atomically.
aif_write_file() {
  local dest="$1"
  local tmp
  mkdir -p "$(dirname "$dest")"
  tmp="$(aif_tmpfile "$dest")"
  cat >"$tmp"
  mv "$tmp" "$dest"
}

# aif_block_inject <file> <begin> <end> <payload>
#
# Idempotently maintain a marked block. Absent file: create it. Block present:
# replace only its contents. Block absent: append.
#
# Appending rather than prepending: it never disturbs what the user already
# wrote, and re-running only ever rewrites between the markers.
#
# awk into a temp file, never `sed -i`: BSD sed reads the argument after -i as a
# backup suffix and then swallows the filename, GNU sed rejects the BSD form,
# and no spelling satisfies both.
aif_block_inject() {
  local file="$1" begin="$2" end="$3" payload="$4"
  local tmp

  if [ ! -f "$file" ]; then
    mkdir -p "$(dirname "$file")"
    printf '%s\n%s\n%s\n' "$begin" "$payload" "$end" >"$file"
    return 0
  fi

  if grep -qF "$begin" "$file"; then
    tmp="$(aif_tmpfile "$file")"
    awk -v b="$begin" -v e="$end" -v p="$payload" '
      index($0, b) { print; print p; skip = 1; next }
      index($0, e) { skip = 0 }
      !skip        { print }
    ' "$file" >"$tmp" && mv "$tmp" "$file"
  else
    printf '\n%s\n%s\n%s\n' "$begin" "$payload" "$end" >>"$file"
  fi
}

# aif_block_remove <file> <begin> <end> — drop our block, leave the rest.
#
# Also takes back the single blank line that aif_block_inject puts in front of
# an appended block. Without that, uninstall leaves the file one line longer
# than it found it, `git diff` is not empty after an install/uninstall round
# trip, and "we reverted our change" is not quite true.
#
# Blank lines are therefore buffered rather than printed as they arrive: when
# the begin marker turns up, one held blank is dropped and the rest are emitted.
aif_block_remove() {
  local file="$1" begin="$2" end="$3"
  local tmp

  [ -f "$file" ] || return 0
  grep -qF "$begin" "$file" || return 0

  tmp="$(aif_tmpfile "$file")"
  awk -v b="$begin" -v e="$end" '
    function flush(n,   i) { for (i = 0; i < n; i++) print "" }
    {
      if (skip)          { if (index($0, e)) skip = 0; next }
      if (index($0, b))  { if (blanks > 0) blanks--; flush(blanks); blanks = 0; skip = 1; next }
      if ($0 == "")      { blanks++; next }
      flush(blanks); blanks = 0
      print
    }
    END { flush(blanks) }
  ' "$file" >"$tmp" && mv "$tmp" "$file"
}

# aif_json_merge <target> <fragment-json>
#
# Recursive merge with `*`, never `+`. `+` is shallow: merging {"env":{"A":2}}
# into {"env":{"A":1,"K":"keep"}} with + yields {"env":{"A":2}} and silently
# destroys K. With * it yields {"env":{"A":2,"K":"keep"}}.
#
# Validate before mv, so a bad merge leaves the original intact.
aif_json_merge() {
  local target="$1" fragment="$2"
  local tmp

  mkdir -p "$(dirname "$target")"
  tmp="$(aif_tmpfile "$target")"

  if [ -f "$target" ]; then
    if ! jq --argjson f "$fragment" '. * $f' "$target" >"$tmp" 2>/dev/null; then
      rm -f "$tmp"
      aif_die "$target is not valid JSON — refusing to merge into it"
    fi
  else
    printf '%s' "$fragment" | jq '.' >"$tmp" 2>/dev/null || {
      rm -f "$tmp"
      aif_die "internal: set fragment is not valid JSON"
    }
  fi

  if ! jq -e . "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    aif_die "merge produced invalid JSON — $target left untouched"
  fi

  mv "$tmp" "$target"
}

# aif_json_unmerge <target> <fragment-json>
#
# Structurally subtract the fragment we merged, then prune what is left empty.
# This is value-guarded by construction: a key is removed only where it still
# deep-equals what we wrote (`.[$k] == $f[$k]`), and an array keeps only the
# elements we did not add (`.[$k] - $f[$k]`). A key the user has since changed no
# longer matches, so it stays — the classic uninstaller sin (taking back a
# setting the user rewrote) cannot happen.
#
# Leaf-path deletion, the previous approach, could not invert a deeply nested
# fragment: removing the scalars left `{"hooks":{"PreToolUse":[{}]}}` behind. The
# recursive subtract plus a prune that clears empty objects AND arrays handles
# the nesting.
aif_json_unmerge() {
  local target="$1" fragment="$2"
  local tmp

  [ -f "$target" ] || return 0

  tmp="$(aif_tmpfile "$target")"
  if ! jq --argjson f "$fragment" '
        def subtract($f):
          reduce ($f | keys_unsorted[]) as $k (.;
            if (has($k) | not) then .
            elif (.[$k] == $f[$k]) then del(.[$k])
            elif ((.[$k] | type) == "object") and (($f[$k] | type) == "object")
              then .[$k] = (.[$k] | subtract($f[$k]))
            elif ((.[$k] | type) == "array") and (($f[$k] | type) == "array")
              then .[$k] = (.[$k] - $f[$k])
            else . end);
        def prune: walk(
          if type == "object" then with_entries(select(.value != {} and .value != []))
          else . end);
        subtract($f) | prune
      ' "$target" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    aif_warn "could not revert $target — left untouched"
    return 1
  fi

  if ! jq -e . "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    aif_warn "reverting $target would produce invalid JSON — left untouched"
    return 1
  fi

  mv "$tmp" "$target"
}

# aif_gitignore_ensure <root> <pattern> <why>
aif_gitignore_ensure() {
  local root="$1" pattern="$2" why="$3"
  local file="$root/.gitignore"

  if [ -f "$file" ] && grep -qxF "$pattern" "$file"; then
    return 0
  fi

  aif_block_inject "$file" "$AIF_MARK_BEGIN_HASH" "$AIF_MARK_END_HASH" \
    "$(printf '# %s\n%s' "$why" "$pattern")"
}
