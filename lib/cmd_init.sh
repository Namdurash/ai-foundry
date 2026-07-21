#!/usr/bin/env bash
#
# `aif init` — scaffold a foundry set into the current project.
# Sourced by bin/aif; not meant to be executed directly.

AIF_DRY_RUN=0
AIF_FORCE=0

_aif_init_usage() {
  cat <<EOF
usage: aif init [profile] [--force] [--dry-run]

  Installs a foundry set into the current git repository. With no profile
  named, prompts for one.

  --dry-run   report what would change, touch nothing
  --force     overwrite files that conflict, keeping a backup
EOF
}

# Everything the set installs, as "source<TAB>destination-relative-to-root".
_aif_set_files() {
  local set_dir="$1"
  local file rel

  if [ -f "$set_dir/foundry.md" ]; then
    printf '%s\t%s\n' "$set_dir/foundry.md" ".aif/foundry.md"
  fi

  if [ -d "$set_dir/skills" ]; then
    find "$set_dir/skills" -type f -print 2>/dev/null | while IFS= read -r file; do
      rel="${file#"$set_dir/skills/"}"
      printf '%s\t%s\n' "$file" ".claude/skills/$rel"
    done
  fi

  if [ -d "$set_dir/agents" ]; then
    find "$set_dir/agents" -type f -print 2>/dev/null | while IFS= read -r file; do
      rel="${file#"$set_dir/agents/"}"
      printf '%s\t%s\n' "$file" ".claude/agents/$rel"
    done
  fi

  # Gates are installed into the project rather than run from AIF_ROOT, so that
  # a fresh CI checkout can verify an artifact without aif on the box. That also
  # makes them versioned alongside the artifacts they gate: an old commit stays
  # checkable against the gates that were current when it was written.
  #
  # project.templates/ is deliberately NOT installed — those are sources for
  # `aif project init` to copy one of, not files the project carries.
  if [ -d "$set_dir/gates" ]; then
    find "$set_dir/gates" -type f -print 2>/dev/null | while IFS= read -r file; do
      rel="${file#"$set_dir/gates/"}"
      printf '%s\t%s\n' "$file" ".aif/gates/$rel"
    done
  fi

  # Station system prompts. Installed into the project so a run is reproducible
  # from the committed tree and versioned alongside the artifacts it produced.
  if [ -d "$set_dir/stations" ]; then
    find "$set_dir/stations" -type f -print 2>/dev/null | while IFS= read -r file; do
      rel="${file#"$set_dir/stations/"}"
      printf '%s\t%s\n' "$file" ".aif/stations/$rel"
    done
  fi

  # Hook scripts. Registered in .claude/settings.json via settings.fragment.json;
  # this installs the scripts they point at.
  if [ -d "$set_dir/hooks" ]; then
    find "$set_dir/hooks" -type f -print 2>/dev/null | while IFS= read -r file; do
      rel="${file#"$set_dir/hooks/"}"
      printf '%s\t%s\n' "$file" ".aif/hooks/$rel"
    done
  fi
}

# The three-way rule. Echoes create | update | conflict.
#
#   absent                     -> create   (first install, or user deleted it)
#   present, not in manifest   -> conflict (it was here before us; not ours to take)
#   present, hash matches      -> update   (we wrote it, nobody touched it)
#   present, hash differs      -> conflict (the user edited our file)
#
# The manifest records the hash we left behind, so "differs" unambiguously means
# a human changed it. Without that distinction, init either clobbers edits or
# can never update anything.
_aif_verdict() {
  local dest="$1" root="$2" rel="$3"
  local recorded actual

  if [ ! -f "$dest" ]; then
    printf 'create'
    return 0
  fi

  recorded="$(aif_manifest_file_hash "$root" "$rel")"
  if [ -z "$recorded" ]; then
    printf 'conflict'
    return 0
  fi

  actual="$(aif_sha256 "$dest")"
  if [ "$actual" = "$recorded" ]; then
    printf 'update'
  else
    printf 'conflict'
  fi
}

_aif_pick_profile() {
  local name desc count=0
  local pick_names=""

  while IFS="$(printf '\t')" read -r name desc; do
    [ -n "$name" ] || continue
    count=$((count + 1))
    pick_names="$pick_names $name"
    printf '  %d) %-12s %s\n' "$count" "$name" "$desc" >&2
  done <<EOF
$(aif_profile_list)
EOF

  [ "$count" -gt 0 ] || aif_die "no profiles found"

  local answer chosen
  printf '\nProfile [1-%d]: ' "$count" >&2
  read -r answer || aif_die "cancelled"

  case "$answer" in
    '' | *[!0-9]*) aif_die "not a number: $answer" ;;
  esac
  [ "$answer" -ge 1 ] 2>/dev/null && [ "$answer" -le "$count" ] ||
    aif_die "out of range: $answer"

  # Word-indexing a space-delimited list: bash 3.2 has no associative arrays and
  # this needs no array at all.
  chosen="$(printf '%s' "$pick_names" | awk -v n="$answer" '{ print $n }')"
  printf '%s' "$chosen"
}

aif_cmd_init() {
  local profile=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) AIF_DRY_RUN=1 ;;
      --force) AIF_FORCE=1 ;;
      -h | --help)
        _aif_init_usage
        return 0
        ;;
      -*) aif_die "unknown option: $1" ;;
      *) profile="$1" ;;
    esac
    shift
  done

  local root
  root="$(aif_require_project)"

  if [ -z "$profile" ]; then
    # Without this guard CI hangs on the prompt forever instead of failing.
    [ -t 0 ] || aif_die "no profile given and stdin is not a TTY — run: aif init <profile>"
    printf 'Which profile should this project use?\n\n' >&2
    profile="$(_aif_pick_profile)"
  fi

  aif_profile_load "$profile"

  local set_dir set_version
  set_dir="$AIF_ROOT/sets/$AIF_PROFILE_SET"
  [ -d "$set_dir" ] || aif_die "profile '$profile' wants set '$AIF_PROFILE_SET', which does not exist"
  set_version="$(aif_meta_get "$set_dir/set.meta" SET_VERSION 0.0.0)"

  # A different set already installed means stale files we do not track. Same
  # set with a different profile is free, though — because routing lives in the
  # environment at start time, never in a config file, so there is nothing stale
  # to clean up. See docs/FINDINGS.md #1.
  local prev_set
  prev_set="$(aif_manifest_get "$root" '.set')"
  if [ -n "$prev_set" ] && [ "$prev_set" != "$AIF_PROFILE_SET" ] && [ "$AIF_FORCE" -eq 0 ]; then
    aif_die "project already has set '$prev_set'; switching to '$AIF_PROFILE_SET' needs --force"
  fi

  if [ "$AIF_DRY_RUN" -eq 1 ]; then
    printf '%s(dry run — nothing will be written)%s\n\n' "$AIF_C_YELLOW" "$AIF_C_RESET"
  fi

  printf 'profile %s%s%s · set %s (%s) · %s\n\n' \
    "$AIF_C_BOLD" "$profile" "$AIF_C_RESET" "$AIF_PROFILE_SET" "$set_version" "$root"

  local files_tsv edits_tsv
  files_tsv="$(mktemp "${TMPDIR:-/tmp}/aif-files-XXXXXX")"
  edits_tsv="$(mktemp "${TMPDIR:-/tmp}/aif-edits-XXXXXX")"

  local created=0 updated=0 unchanged=0 conflicts=0
  local src rel dest verdict digest

  while IFS="$(printf '\t')" read -r src rel; do
    [ -n "$rel" ] || continue
    dest="$root/$rel"
    verdict="$(_aif_verdict "$dest" "$root" "$rel")"

    if [ "$verdict" = "conflict" ] && [ "$AIF_FORCE" -eq 0 ]; then
      conflicts=$((conflicts + 1))
      printf '  %sconflict%s  %s\n' "$AIF_C_RED" "$AIF_C_RESET" "$rel"
      printf '            %snot ours, or edited since we wrote it — skipped (--force to take it)%s\n' \
        "$AIF_C_DIM" "$AIF_C_RESET"
      # Keep the previously recorded hash so a later run still sees the edit.
      digest="$(aif_manifest_file_hash "$root" "$rel")"
      if [ -n "$digest" ]; then
        printf '%s\t%s\n' "$rel" "$digest" >>"$files_tsv"
      fi
      continue
    fi

    if [ "$verdict" = "update" ] && cmp -s "$src" "$dest"; then
      unchanged=$((unchanged + 1))
      digest="$(aif_sha256 "$dest")"
      printf '%s\t%s\n' "$rel" "$digest" >>"$files_tsv"
      continue
    fi

    if [ "$AIF_DRY_RUN" -eq 0 ]; then
      if [ "$verdict" = "conflict" ] && [ -f "$dest" ]; then
        mkdir -p "$root/.aif/backups"
        cp "$dest" "$root/.aif/backups/$(basename "$rel").orig"
      fi
      mkdir -p "$(dirname "$dest")"
      cp "$src" "$dest"
      digest="$(aif_sha256 "$dest")"
      printf '%s\t%s\n' "$rel" "$digest" >>"$files_tsv"
    fi

    if [ "$verdict" = "create" ]; then
      created=$((created + 1))
      printf '  %screate%s    %s\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$rel"
    else
      updated=$((updated + 1))
      printf '  %supdate%s    %s\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$rel"
    fi
  done <<EOF
$(_aif_set_files "$set_dir")
EOF

  # The set's settings fragment, if it ships one. Model routing never goes here.
  local fragment settings_dest pre_existed clobbers
  settings_dest="$root/.claude/settings.json"
  if [ -f "$set_dir/settings.fragment.json" ]; then
    fragment="$(cat "$set_dir/settings.fragment.json")"

    # A `*` merge REPLACES arrays rather than appending, so merging our hook into
    # a settings.json that already has PreToolUse hooks would drop the user's.
    # Refuse in that case rather than clobber — the guard hook is defence in
    # depth (green's hash-lock is the real arbiter), so skipping it is safe.
    clobbers=no
    if [ -f "$settings_dest" ]; then
      printf '%s' "$fragment" | jq -e '.hooks.PreToolUse' >/dev/null 2>&1 &&
        jq -e '.hooks.PreToolUse' "$settings_dest" >/dev/null 2>&1 && clobbers=yes
    fi

    if [ "$clobbers" = "yes" ]; then
      aif_warn "you already have PreToolUse hooks — skipping the guard hook so yours are not replaced"
      aif_warn "  register it yourself from .aif/hooks/guard.sh if you want the test/impl guard"
    else
      # Whether the file existed decides uninstall's cleanup: a file we created
      # and then emptied is our litter to remove; a file the user had stays.
      pre_existed="no"
      [ -f "$settings_dest" ] && pre_existed="yes"

      printf '  %smerge%s     .claude/settings.json\n' "$AIF_C_GREEN" "$AIF_C_RESET"
      if [ "$AIF_DRY_RUN" -eq 0 ]; then
        aif_json_merge "$settings_dest" "$fragment"
      fi
      # Store the fragment itself: uninstall subtracts it structurally, which is
      # value-guarded and handles the nested hook array a leaf-path list cannot.
      printf '%s\t%s\t%s\t%s\n' ".claude/settings.json" "json_merge" \
        "$(printf '%s' "$fragment" | jq -c .)" "$pre_existed" >>"$edits_tsv"
    fi
  fi

  # One line into CLAUDE.md, and only if the set actually has always-on content.
  if [ -f "$set_dir/foundry.md" ]; then
    printf '  %simport%s    CLAUDE.md\n' "$AIF_C_GREEN" "$AIF_C_RESET"
    if [ "$AIF_DRY_RUN" -eq 0 ]; then
      aif_block_inject "$root/CLAUDE.md" \
        "$AIF_MARK_BEGIN_MD" "$AIF_MARK_END_MD" "@.aif/foundry.md"
    fi
    # The kind names the marker style, so uninstall never has to guess it from
    # the filename.
    printf '%s\t%s\n' "CLAUDE.md" "marker_block_md" >>"$edits_tsv"
  fi

  # Record every edit BEFORE the manifest is written — anything appended after
  # aif_manifest_write has already read these files is silently lost, and an
  # untracked edit is one uninstall will never revert.
  printf '%s\t%s\n' ".gitignore" "marker_block_hash" >>"$edits_tsv"

  if [ "$AIF_DRY_RUN" -eq 0 ]; then
    # Both patterns in one managed block: the profile (per-developer, never
    # committed) and .aif/tmp/ (gates' scratch — a test report left there would
    # otherwise trip scope's denylist and land in a station commit). One call,
    # because a second aif_gitignore_ensure would replace the block, not extend
    # it.
    aif_block_inject "$root/.gitignore" \
      "$AIF_MARK_BEGIN_HASH" "$AIF_MARK_END_HASH" \
      "$(printf '# per-developer model choice; the shared set is committed\n%s\n# gate scratch\n%s' \
        "$AIF_PROFILE_STATE" ".aif/tmp/")"

    printf '%s\n' "$profile" | aif_write_file "$root/$AIF_PROFILE_STATE"
    # Ours, so the ledger owns it too, even though no set ships it.
    printf '%s\t%s\n' "$AIF_PROFILE_STATE" "$(aif_sha256 "$root/$AIF_PROFILE_STATE")" \
      >>"$files_tsv"

    aif_manifest_write "$root" "$profile" "$AIF_PROFILE_SET" "$set_version" \
      "$files_tsv" "$edits_tsv"
  fi

  rm -f "$files_tsv" "$edits_tsv"

  printf '\n  %d created, %d updated, %d unchanged' "$created" "$updated" "$unchanged"
  if [ "$conflicts" -gt 0 ]; then
    printf ', %s%d conflicts%s' "$AIF_C_RED" "$conflicts" "$AIF_C_RESET"
  fi
  printf '\n'

  if [ "$AIF_DRY_RUN" -eq 1 ]; then
    return 0
  fi

  if [ -n "$AIF_PROFILE_SECRET_VAR" ] && [ -z "$(aif_profile_secret)" ]; then
    printf '\n'
    aif_warn "$AIF_PROFILE_SECRET_VAR is not set — export it before running aif start"
  fi

  [ "$conflicts" -eq 0 ]
}
