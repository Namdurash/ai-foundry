#!/usr/bin/env bash
#
# Detection of agentic CLIs ("runners") and the tooling aif depends on.
# Sourced by bin/aif; not meant to be executed directly.

# The agentic CLIs aif knows about. Space-separated because bash 3.2 has no
# associative arrays and a plain word list iterates cleanly.
AIF_RUNNERS="claude codex gemini qwen opencode"

# aif_runner_path <runner> — absolute path, or empty if absent.
aif_runner_path() {
  command -v "$1" 2>/dev/null || true
}

# aif_runner_version <runner> — first line of `<runner> --version`, or empty.
#
# Every runner we target accepts --version except qwen, where it is
# undocumented (the project points at `/doctor` instead). An empty result is
# reported as "?" rather than treated as absent: presence is decided by path.
aif_runner_version() {
  local runner="$1"
  aif_have "$runner" || return 0
  "$runner" --version 2>/dev/null | head -1 | tr -d '\r\n' || true
}

# aif_runners_available — the subset of AIF_RUNNERS present on this machine,
# space-separated on stdout.
aif_runners_available() {
  local r out=""
  for r in $AIF_RUNNERS; do
    if aif_have "$r"; then
      out="$out $r"
    fi
  done
  # Trim the leading space without ${var## } gymnastics.
  printf '%s' "${out# }"
}
