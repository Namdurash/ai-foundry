#!/usr/bin/env bash
#
# `aif profiles` — list the available (set, runner, model) profiles.
# Sourced by bin/aif; not meant to be executed directly.

aif_cmd_profiles() {
  local name desc runner set_name secret_var have
  local any=0

  # 13 + 1 here matches the marker (1) + space (1) + %-11s (11) + space (1) of a
  # row below. Colour stays outside the padded fields, or it counts toward the
  # width and the columns drift.
  printf '%s%-13s %-10s %-8s %s%s\n' \
    "$AIF_C_BOLD" "PROFILE" "RUNNER" "SET" "DESCRIPTION" "$AIF_C_RESET"

  while IFS="$(printf '\t')" read -r name desc; do
    [ -n "$name" ] || continue
    any=1

    local file
    file="$(aif_profile_find "$name")" || continue
    runner="$(_aif_profile_field "$file" AIF_PROFILE_RUNNER)"
    set_name="$(_aif_profile_field "$file" AIF_PROFILE_SET)"
    secret_var="$(_aif_profile_field "$file" AIF_PROFILE_SECRET_VAR)"

    if aif_have "$runner"; then
      have="$(aif_ok)"
    else
      have="$(aif_no)"
    fi

    printf '%s %-11s %-10s %-8s %s\n' "$have" "$name" "$runner" "$set_name" "$desc"

    # Report only whether the token is present. Never its value, never a prefix.
    if [ -n "$secret_var" ]; then
      if [ -n "$(eval "printf '%s' \"\${$secret_var:-}\"")" ]; then
        printf '    %s%s is set%s\n' "$AIF_C_DIM" "$secret_var" "$AIF_C_RESET"
      else
        printf '    %s%s is not set — export it to use this profile%s\n' \
          "$AIF_C_YELLOW" "$secret_var" "$AIF_C_RESET"
      fi
    fi
  done <<EOF
$(aif_profile_list)
EOF

  if [ "$any" -eq 0 ]; then
    aif_warn "no profiles found"
    return 1
  fi

  printf '\n%sAdd your own: drop a .profile file in %s/aif/profiles%s\n' \
    "$AIF_C_DIM" "${XDG_CONFIG_HOME:-$HOME/.config}" "$AIF_C_RESET"
}
