#!/usr/bin/env bash
#
# Roles, and what each one requires of the machine.
# Sourced by bin/aif; not meant to be executed directly.
#
# The failure this exists for is FINDINGS #11 at the level of roles: a project
# manager skill that silently cannot reach the board reads as "nothing
# happened", exactly like a meter hook that could not run. So every role
# declares what it needs, `aif doctor` probes each capability for real, and the
# table it prints says per role: ready, or not, and what is missing.
#
# Two sources, one list:
#
#   - the worker is not a skill — it is `aif work` — so its requirements are
#     declared here;
#   - every skill the set ships declares its own in its frontmatter
#     (`requires: [board]`), and the skill's name minus `aif-` is the role. A
#     skill that arrives later needs no change here.
#
# A capability is a NAMED PROBE in lib/doctor.sh (_aif_doctor_caps), never a
# file check alone: `board` is "a token is set, one call to the API succeeded,
# and the six columns exist", not "a token exists". A role that names a
# capability no probe knows is reported as not ready with "unknown capability"
# — a typo in a skill's frontmatter must not read as ready.

# aif_roles_builtin — "role<TAB>requires…" for roles that are not skills.
aif_roles_builtin() {
  printf 'worker\tclaude git-worktree test-toolchain board\n'
}

# aif_role_requires_of_skill <SKILL.md> — the `requires:` list, space-separated.
#
# Flat YAML only — `requires: [board, claude]` or `requires: []` — which is all
# the set writes. A real parser is a dependency this cannot assume.
aif_role_requires_of_skill() {
  awk '
    NR == 1 && $0 == "---" { inblock = 1; next }
    inblock && $0 == "---" { exit }
    inblock && index($0, "requires:") == 1 {
      sub(/^requires:[ \t]*/, ""); gsub(/[\[\]]/, ""); gsub(/,/, " "); print; exit }
  ' "$1" 2>/dev/null | tr -s ' ' | sed 's/^ *//; s/ *$//'
}

# aif_roles_all <root> — "role<TAB>requires…" per line: the builtin ones, then
# every installed aif-* skill. A skill with no `requires:` line requires
# nothing and is still listed, because a role nobody lists cannot be reported
# as ready.
aif_roles_all() {
  local root="$1" skill role req
  aif_roles_builtin
  for skill in "$root"/.claude/skills/aif-*/SKILL.md; do
    [ -f "$skill" ] || continue
    role="$(basename "$(dirname "$skill")")"
    role="${role#aif-}"
    [ "$role" != "aif" ] || continue
    req="$(aif_role_requires_of_skill "$skill")"
    printf '%s\t%s\n' "$role" "$req"
  done
}
