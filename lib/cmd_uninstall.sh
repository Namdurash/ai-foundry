#!/usr/bin/env bash
#
# `aif uninstall` — reverse the manifest.
# Sourced by bin/aif; not meant to be executed directly.
#
# The mirror of init, and it inherits init's discipline: remove exactly what we
# put there and nothing else. A file the user has edited since we wrote it is
# theirs now, and a good uninstaller leaves it alone rather than tidying away
# work it did not do.

_aif_uninstall_usage() {
  cat <<EOF
usage: aif uninstall [--force] [--dry-run]

  Removes the foundry set this project was initialised with, reverting only
  what aif installed.

  --dry-run   report what would be removed, touch nothing
  --force     also remove files you have edited since aif wrote them
EOF
}

# Remove directories left empty by our own removals, walking up to the project
# root. rmdir refuses to touch a non-empty directory, which is exactly the guard
# we want: the moment we hit a directory holding anything else, we stop.
_aif_prune_empty() {
  local root="$1" rel="$2"
  local dir
  dir="$(dirname "$root/$rel")"
  while [ "$dir" != "$root" ] && [ "$dir" != "/" ]; do
    rmdir "$dir" 2>/dev/null || break
    dir="$(dirname "$dir")"
  done
}

aif_cmd_uninstall() {
  AIF_DRY_RUN=0
  AIF_FORCE=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) AIF_DRY_RUN=1 ;;
      --force) AIF_FORCE=1 ;;
      -h | --help)
        _aif_uninstall_usage
        return 0
        ;;
      *) aif_die "unknown option: $1" ;;
    esac
    shift
  done

  local root manifest
  root="$(aif_require_project)"
  manifest="$(aif_manifest_path "$root")"
  [ -f "$manifest" ] || aif_die "nothing installed here — no .aif/manifest.json"

  local profile set_name
  profile="$(aif_manifest_get "$root" '.profile')"
  set_name="$(aif_manifest_get "$root" '.set')"

  if [ "$AIF_DRY_RUN" -eq 1 ]; then
    printf '%s(dry run — nothing will be removed)%s\n\n' "$AIF_C_YELLOW" "$AIF_C_RESET"
  fi
  printf 'removing set %s%s%s (profile %s) from %s\n\n' \
    "$AIF_C_BOLD" "$set_name" "$AIF_C_RESET" "$profile" "$root"

  local removed=0 kept=0 missing=0
  local rel recorded actual

  while IFS="$(printf '\t')" read -r rel recorded; do
    [ -n "$rel" ] || continue

    if [ ! -f "$root/$rel" ]; then
      missing=$((missing + 1))
      continue
    fi

    actual="$(aif_sha256 "$root/$rel")"
    if [ "$actual" != "$recorded" ] && [ "$AIF_FORCE" -eq 0 ]; then
      kept=$((kept + 1))
      printf '  %skept%s      %s\n' "$AIF_C_YELLOW" "$AIF_C_RESET" "$rel"
      printf '            %sedited since aif wrote it — yours now (--force to remove)%s\n' \
        "$AIF_C_DIM" "$AIF_C_RESET"
      continue
    fi

    removed=$((removed + 1))
    printf '  %sremove%s    %s\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$rel"
    if [ "$AIF_DRY_RUN" -eq 0 ]; then
      rm -f "$root/$rel"
      _aif_prune_empty "$root" "$rel"
    fi
  done <<EOF
$(jq -r '.files[]? | [.path, .sha256] | @tsv' "$manifest")
EOF

  local kind entries
  while IFS="$(printf '\t')" read -r rel kind entries; do
    [ -n "$rel" ] || continue
    [ -f "$root/$rel" ] || continue

    case "$kind" in
      marker_block_md)
        printf '  %srevert%s    %s\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$rel"
        if [ "$AIF_DRY_RUN" -eq 0 ]; then
          aif_block_remove "$root/$rel" "$AIF_MARK_BEGIN_MD" "$AIF_MARK_END_MD"
        fi
        ;;
      marker_block_hash)
        printf '  %srevert%s    %s\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$rel"
        if [ "$AIF_DRY_RUN" -eq 0 ]; then
          aif_block_remove "$root/$rel" "$AIF_MARK_BEGIN_HASH" "$AIF_MARK_END_HASH"
        fi
        ;;
      json_merge)
        printf '  %srevert%s    %s\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$rel"
        if [ "$AIF_DRY_RUN" -eq 0 ]; then
          aif_json_unmerge "$root/$rel" "${entries:-[]}" || true
        fi
        ;;
      *)
        # Never fail quietly on an edit we do not know how to undo: a leftover
        # the user cannot see is worse than a loud complaint.
        aif_warn "don't know how to revert '$kind' on $rel — left in place"
        ;;
    esac
  done <<EOF
$(jq -r '.edits[]? | [.path, .kind, ((.entries // []) | tojson)] | @tsv' "$manifest")
EOF

  if [ "$AIF_DRY_RUN" -eq 0 ]; then
    rm -f "$manifest"
    _aif_prune_empty "$root" ".aif/manifest.json"
  fi

  printf '\n  %d removed, %d missing already' "$removed" "$missing"
  if [ "$kept" -gt 0 ]; then
    printf ', %s%d kept%s' "$AIF_C_YELLOW" "$kept" "$AIF_C_RESET"
  fi
  printf '\n'

  # Backups hold the user's own content, copied aside when --force took a file
  # over. Deleting them here would destroy the very thing they exist to protect.
  if [ -d "$root/.aif/backups" ]; then
    printf '\n'
    aif_warn "kept $root/.aif/backups — your files, remove them yourself"
  fi
}
