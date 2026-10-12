#!/usr/bin/env bash
#
# `aif setup` — the project set up for aif by the model it works with.
# Sourced by bin/aif; not meant to be executed directly.
#
# aif's gates need four facts from a project's tests, whatever its stack:
# a report, a new test collected and named by its file, the criterion's
# marker kept in its id, a failing assertion read as a red. They were
# templates aif shipped for two runners, and a project on any other — vitest,
# go test, xcodebuild, an engine's automation — could not be set up at all
# (docs/DEFECTS.md 20.1). Now this command opens one claude session, on the
# project's own profile, with the aif-setup skill as its procedure: the model
# reads how this project's tests run and writes the contract into
# .aif/project.json — the command, the report, test.files, deps, copies, the
# failure classes, the probe — with .aif/stack.md for the stations and, where
# the runner writes no JUnit of its own, an adapter under .aif/adapter/.
#
# What makes that stable rather than a model's guess is what checks it: the
# project's own gate, .aif/gates/probe.sh, writes the probe test into a copy
# of the tree and reads the report as verify-red would, and `aif doctor
# --probe` is what the session ends on. The worker proves it again before a
# run whenever what it stands on has moved. A model writes the contract; bash
# proves it — the order of trust /aif-setup has always had.
#
# The session is the person's: every install, every commit and every change
# outside .aif/ waits for their yes, and no token passes through it.

_aif_setup_usage() {
  cat <<EOF
usage: aif setup [--model <model>] [--print]

  Opens a Claude Code session on this project's profile that sets aif up for
  this project's stack — its test runner, its report, the probe that proves
  both, the stations' notes on the stack — and ends on aif doctor --probe.
  Run it after aif init (which offers it), and again whenever the project's
  test setup changes: the worker refuses a run while the probe does not hold.

  --model <m>  the model the session runs on (default: the project's careful
               tier, else opus) — as the profile maps it
  --print      print the session's opening message and note; open nothing
EOF
}

# _aif_setup_facts <root> — what aif reads before the session, as one
# paragraph for its first message: the runner the repository suggests, the
# state of .aif/project.json and of the contract, the build and package files
# at the root. Facts, so the model starts from what is there rather than
# from a guess — and every one of them is a thing it can check.
_aif_setup_facts() {
  local root="$1" config detected state files="" f t
  detected="$(_aif_detect_runner "$root")"
  config="$(aif_project_config "$root")"
  if [ ! -f "$config" ]; then
    state="there is no .aif/project.json yet"
  elif ! aif_project_set_up "$config"; then
    state=".aif/project.json is the base template, its test contract not written (test.kind \"$(aif_project_kind_recorded "$config")\")"
  else
    state=".aif/project.json is set up (test.kind \"$(aif_project_kind "$config")\", test.command \"$(jq -r '.test.command' "$config")\")"
    case "$(aif_project_probe "$root" --proven >/dev/null 2>&1; echo $?)" in
      0) state="$state, and the probe has proven it" ;;
      5) state="$state, not proven since what the probe stands on last moved" ;;
      *) state="$state, and the probe says the contract does not hold — aif doctor --probe shows why" ;;
    esac
  fi
  for f in package.json pyproject.toml setup.cfg requirements.txt go.mod Cargo.toml Gemfile Podfile \
    Package.swift build.gradle build.gradle.kts settings.gradle settings.gradle.kts pom.xml \
    CMakeLists.txt Makefile composer.json mix.exs deno.json pubspec.yaml; do
    [ ! -e "$root/$f" ] || files="$files${files:+, }$f"
  done
  for f in "$root"/*.uproject "$root"/*.xcodeproj "$root"/*.xcworkspace "$root"/*.sln "$root"/*.csproj; do
    [ -e "$f" ] || continue
    files="$files${files:+, }${f##*/}"
  done
  t=""
  [ ! -f "$root/package.json" ] || t="$(jq -r '.scripts.test // empty' "$root/package.json" 2>/dev/null)"
  printf 'Facts aif read before this session: the repository suggests the runner "%s"; %s; at the root: %s%s.' \
    "${detected:-none it knows}" "$state" "${files:-no build or package file aif knows by name}" \
    "${t:+; package.json scripts.test is \"$t\"}"
}

aif_cmd_setup() {
  local model="" print=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --model)
        [ $# -ge 2 ] || aif_die "--model needs a model"
        model="$2"
        shift
        ;;
      --print) print=1 ;;
      -h | --help)
        _aif_setup_usage
        return 0
        ;;
      *) aif_die "unknown option: $1 (try: aif setup --help)" ;;
    esac
    shift
  done

  local root main profile config prompt rc=0
  root="$(aif_require_project)"
  main="$(aif_main_root "$root")"
  [ "$root" = "$main" ] ||
    aif_die "this is a worker's checkout, not the main one — set up from: cd $(aif_shq "$main")"
  [ -f "$root/.claude/skills/aif-setup/SKILL.md" ] ||
    aif_die "aif is not installed here — run: aif init (it offers aif setup when it is done)"
  [ -f "$root/$AIF_PROFILE_STATE" ] ||
    aif_die "no profile chosen for this project — run: aif init"
  profile="$(tr -d '[:space:]' <"$root/$AIF_PROFILE_STATE")"
  aif_profile_load "$profile"
  [ "$AIF_PROFILE_RUNNER" = claude ] ||
    aif_die "aif setup opens a claude session; profile $profile runs $AIF_PROFILE_RUNNER"

  config="$(aif_project_config "$root")"
  if [ -z "$model" ]; then
    model="$(jq -r '.tiers.careful // empty' "$config" 2>/dev/null)" || model=""
    [ -n "$model" ] || model=opus
  fi
  prompt="/aif-setup $(_aif_setup_facts "$root")"

  if [ "$print" -eq 1 ]; then
    printf 'profile: %s · model: %s\n\n%s\n\n%s\n' "$profile" "$model" "$prompt" "$AIF_RUNNER_CLAUDE_SETUP_NOTE"
    return 0
  fi

  aif_profile_export_env
  if [ "${AIF_PROFILE_ISOLATE_CONFIG:-0}" = "1" ]; then
    CLAUDE_CONFIG_DIR="$(aif_runner_config_dir "$profile")"
    export CLAUDE_CONFIG_DIR
    mkdir -p "$CLAUDE_CONFIG_DIR"
  fi
  if [ -z "${AIF_START_SESSION_CMD:-}" ]; then
    aif_runner_claude_available || aif_die "claude is not installed — brew install --cask claude-code"
    if [ -n "$AIF_PROFILE_SECRET_VAR" ] && [ -z "$(aif_profile_secret)" ]; then
      aif_die "$AIF_PROFILE_SECRET_VAR is not set — export it to use profile '$profile'"
    fi
  fi
  # An alias the profile does not map would go to its endpoint as it is,
  # and fail there after the session opened (docs/DEFECTS.md 14.6).
  if ! aif_profile_maps_model "$model"; then
    aif_die "the profile $profile does not map $model (it maps $(aif_profile_mapped_aliases)) — aif setup --model <one of those, or a full model id>"
  fi

  printf '%saif setup%s — %s on %s · /exit when it is done\n' "$AIF_C_BOLD" "$AIF_C_RESET" "$model" "$profile"
  aif_runner_claude_session "$root" "$prompt" "$model" "aif setup" "" "$AIF_RUNNER_CLAUDE_SETUP_NOTE" || rc=$?

  # What the session left, said by the verifier rather than by the session.
  printf '\n'
  config="$(aif_project_config "$root")"
  if [ ! -f "$config" ] || ! aif_project_set_up "$config"; then
    printf 'the test contract is not set up yet — aif setup again picks up where this one stopped\n'
    return 1
  fi
  case "$(aif_project_probe "$root" --proven >/dev/null 2>&1; echo $?)" in
    0)
      printf '%s✓%s the test contract holds — proven by .aif/gates/probe.sh\n' "$AIF_C_GREEN" "$AIF_C_RESET"
      printf 'next: %saif doctor%s — what else each role needs here; then /aif-ba in a Claude Code session, and aif work\n' "$AIF_C_BOLD" "$AIF_C_RESET"
      ;;
    *)
      printf 'the test contract is not proven — %saif doctor --probe%s says why; aif setup again fixes it with you\n' "$AIF_C_BOLD" "$AIF_C_RESET"
      return 1
      ;;
  esac
  return "$rc"
}
