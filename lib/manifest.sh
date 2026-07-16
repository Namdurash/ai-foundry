#!/usr/bin/env bash
#
# The ownership ledger: what aif put in this project, and what it changed.
# Sourced by bin/aif; not meant to be executed directly.
#
# Two categories, and the distinction is the whole point:
#
#   files — we own them outright. We may overwrite them; uninstall deletes them.
#   edits — surgical changes inside files that belong to the user. Uninstall
#           reverts only our contribution and leaves the rest alone.
#
# Without this, `init` on an already-initialised project has to guess what it
# wrote last time, and guessing means either clobbering the user's edits or
# refusing to update anything.

AIF_MANIFEST_SCHEMA=1

aif_manifest_path() {
  printf '%s/.aif/manifest.json' "$1"
}

aif_manifest_exists() {
  [ -f "$(aif_manifest_path "$1")" ]
}

# aif_manifest_get <root> <jq-path> — a scalar, or empty.
aif_manifest_get() {
  local root="$1" path="$2"
  local file
  file="$(aif_manifest_path "$root")"
  [ -f "$file" ] || return 0
  jq -r "$path // empty" "$file" 2>/dev/null
}

# aif_manifest_file_hash <root> <relpath> — the digest we recorded after last
# writing this file, or empty if we have never written it.
aif_manifest_file_hash() {
  local root="$1" rel="$2"
  local file
  file="$(aif_manifest_path "$root")"
  [ -f "$file" ] || return 0
  jq -r --arg p "$rel" '.files[]? | select(.path == $p) | .sha256' "$file" 2>/dev/null | head -1
}

# aif_manifest_write <root> <profile> <set> <set_version> <files-tsv> <edits-tsv>
#
# files-tsv: "relpath<TAB>sha256" per line.
# edits-tsv: "relpath<TAB>kind" per line.
aif_manifest_write() {
  local root="$1" profile="$2" set_name="$3" set_version="$4"
  local files_tsv="$5" edits_tsv="$6"
  local dest stamp

  dest="$(aif_manifest_path "$root")"
  stamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  # Built with jq rather than string-concatenated so that a path containing a
  # quote cannot produce broken JSON.
  jq -n \
    --argjson schema "$AIF_MANIFEST_SCHEMA" \
    --arg aif_version "$AIF_VERSION" \
    --arg profile "$profile" \
    --arg set_name "$set_name" \
    --arg set_version "$set_version" \
    --arg stamp "$stamp" \
    --rawfile files_raw "$files_tsv" \
    --rawfile edits_raw "$edits_tsv" \
    '
    def rows($raw; $keys):
      $raw
      | split("\n")
      | map(select(length > 0) | split("\t"))
      | map(. as $r | reduce range(0; $keys | length) as $i ({}; .[$keys[$i]] = $r[$i]));

    {
      schema:       $schema,
      aif_version:  $aif_version,
      profile:      $profile,
      set:          $set_name,
      set_version:  $set_version,
      installed_at: $stamp,
      files:        rows($files_raw; ["path", "sha256"]),
      edits:        rows($edits_raw; ["path", "kind"])
    }
    ' >"$dest.tmp" || aif_die "failed to build manifest"

  mv "$dest.tmp" "$dest"
}
