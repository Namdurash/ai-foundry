#!/usr/bin/env bash
#
# `aif station run <station> <ticket>` — run one pipeline station headless.
# Sourced by bin/aif; not meant to be executed directly.
#
# This is the instrumented path the whole tiering claim rests on. aif invokes
# claude -p itself, so the JSON envelope carries the token usage the ledger
# needs — an in-session subagent would report none (FINDINGS #7 territory). The
# skills in a later milestone are thin wrappers that shell out to this.
#
# The station declares a tier (low|medium|high). project.json maps the tier to a
# model alias (opus|sonnet|haiku). The profile's environment maps the alias to a
# concrete model (opus → glm-5.2 on the glm profile). Three levels, so the set
# stays model-agnostic while a station still says how much engine it needs.

_aif_station_usage() {
  cat <<EOF
usage: aif station run <station> <ticket> [--profile P]

  Runs a station headless and records its cost in the ledger. The station's
  output is then checked by its form gate.
EOF
}

_aif_station_run() {
  local root="$1" station="$2" ticket="$3" profile="$4"
  local work station_file project

  [ -n "$station" ] || aif_die "usage: aif station run <station> <ticket>"
  [ -n "$ticket" ] || aif_die "usage: aif station run <station> <ticket>"

  work="$root/.aif/work/$ticket"
  [ -d "$work" ] || aif_die "no such ticket: $ticket (start it with: aif work new $ticket)"

  station_file="$root/.aif/stations/$station.md"
  [ -f "$station_file" ] || aif_die "no such station: $station"

  project="$(aif_project_config "$root")"
  [ -f "$project" ] || aif_die "no .aif/project.json — run 'aif project init'"

  # Profile: recorded by init unless overridden. Needed for the model remap and
  # for the env export that makes this work on a non-Anthropic provider.
  if [ -z "$profile" ]; then
    if [ -f "$root/$AIF_PROFILE_STATE" ]; then
      profile="$(cat "$root/$AIF_PROFILE_STATE")"
    else
      aif_die "no profile — run 'aif init' or pass --profile"
    fi
  fi
  aif_profile_load "$profile"

  # shellcheck source=lib/runner_claude.sh
  . "$AIF_ROOT/lib/runner_claude.sh"
  "aif_runner_${AIF_PROFILE_RUNNER}_available" ||
    aif_die "runner '$AIF_PROFILE_RUNNER' is not installed"
  if [ -n "$AIF_PROFILE_SECRET_VAR" ] && [ -z "$(aif_profile_secret)" ]; then
    aif_die "$AIF_PROFILE_SECRET_VAR is not set — export it to use profile '$profile'"
  fi

  local meta tier produces form_gate judges freezes model max_turns
  meta="$(aif_meta_json "$station_file")"
  tier="$(printf '%s' "$meta" | jq -r '.tier // "high"')"
  # produces: a single artifact written into the work dir (spec.md, plan.md). A
  # station that writes into the project instead (the test-author writes test
  # files) has none; its form gate does the verifying and freezes the boundary.
  produces="$(printf '%s' "$meta" | jq -r '.produces // empty')"
  form_gate="$(printf '%s' "$meta" | jq -r '.form_gate // empty')"
  # A judge station declares the artifact it judges. aif hashes that artifact and
  # tells the judge the value to record, so the verdict binds to the exact bytes
  # judged — a later edit invalidates it, same as every other *_sha256 binding.
  judges="$(printf '%s' "$meta" | jq -r '.judges // empty')"
  # freezes: the artifact the form gate writes to record this boundary (the
  # test-author station freezes tests.lock). It, not the model's scattered
  # output, is what the next station's precondition binds to.
  freezes="$(printf '%s' "$meta" | jq -r '.freezes // empty')"
  [ -n "$produces" ] || [ -n "$form_gate" ] ||
    aif_die "station '$station' declares neither 'produces' nor 'form_gate' — nothing to verify"

  model="$(jq -r --arg t "$tier" '.tiers[$t] // empty' "$project")"
  [ -n "$model" ] || aif_die "project.json has no tier mapping for '$tier'"
  max_turns="$(jq -r '.limits.station_max_turns // 30' "$project")"

  local tools
  tools="$(printf '%s' "$meta" | jq -r '.tools // "Read Write Edit"')"

  # Preconditions: the state machine, enforced before a token is spent. A
  # station may run only if every gate on its upstream boundaries passes against
  # current bytes — "passes now", not "passed once". Editing an upstream artifact
  # invalidates its gates on its own, so this needs no separate "go back".
  local gate gp pout prc
  while IFS= read -r gate; do
    [ -n "$gate" ] || continue
    gp="$root/.aif/gates/$gate.sh"
    [ -f "$gp" ] || continue # gate from a later milestone; skip
    prc=0
    pout="$(/bin/bash "$gp" "$work" 2>&1)" || prc=$?
    if [ "$prc" -ne 0 ]; then
      aif_die "precondition not met for '$station': $gate — $(printf '%s' "$pout" | head -1). Resolve the upstream artifact first."
    fi
  done <<EOF
$(printf '%s' "$meta" | jq -r '.requires[]? // empty')
EOF

  # The user prompt names the ticket and the target; the station's system prompt
  # (its file body) says what to read and how. A judge additionally gets the hash
  # of the artifact it judges, to record as the verdict's binding.
  local user_prompt sys_prompt out err
  user_prompt="Ticket ${ticket}. Your working directory is the project root. Produce .aif/work/${ticket}/${produces} exactly as your instructions specify; read the inputs your instructions name under .aif/work/${ticket}/."
  if [ -n "$judges" ]; then
    local judged_hash
    judged_hash="$(aif_sha256 "$work/$judges")"
    [ -n "$judged_hash" ] || aif_die "cannot judge $judges — it does not exist for $ticket"
    user_prompt="$user_prompt You are judging .aif/work/${ticket}/${judges}, whose sha256 is ${judged_hash}. Record exactly that value as subject_sha256 in your verdict."
  fi
  sys_prompt="$(mktemp "${TMPDIR:-/tmp}/aif-sys-XXXXXX")"
  aif_meta_body "$station_file" >"$sys_prompt"
  out="$(mktemp "${TMPDIR:-/tmp}/aif-out-XXXXXX")"
  err="$(mktemp "${TMPDIR:-/tmp}/aif-err-XXXXXX")"

  aif_profile_export_env
  if [ "${AIF_PROFILE_ISOLATE_CONFIG:-0}" = "1" ]; then
    CLAUDE_CONFIG_DIR="$(aif_runner_config_dir "$profile")"
    export CLAUDE_CONFIG_DIR
    mkdir -p "$CLAUDE_CONFIG_DIR"
  fi

  printf '%sstation%s %s · tier %s → model %s · profile %s\n' \
    "$AIF_C_DIM" "$AIF_C_RESET" "$station" "$tier" "$model" "$profile" >&2

  # A non-zero exit is expected on a failed run — claude -p still writes the
  # envelope — so the outcome is read from the envelope (is_error), not the exit
  # code. `|| true` keeps set -e from killing us before we can read it.
  "aif_runner_${AIF_PROFILE_RUNNER}_station" \
    "$root" "$sys_prompt" "$user_prompt" "$model" "$max_turns" "$tools" \
    "$out" "$err" || true

  rm -f "$sys_prompt"

  # Record the attempt regardless of outcome — a failed station still cost
  # tokens, and principle 7 counts what was spent, not only what succeeded.
  local attempt usage reported dur turns
  attempt=$(($(jq --arg s "$station" \
    '[.entries[] | select(.station == $s)] | length' \
    "$(aif_ledger_path "$work")") + 1))

  if [ ! -s "$out" ]; then
    aif_ledger_append "$work" "$(jq -n --arg s "$station" --argjson a "$attempt" \
      --arg m "$model" '{ station: $s, attempt: $a, model: $m, result: "no-output" }')"
    aif_die "station produced no output — $(head -1 "$err" 2>/dev/null)"
  fi

  usage="$(aif_runner_claude_result_usage "$out")"
  reported="$(jq -r '.total_cost_usd // 0' "$out")"
  dur="$(jq -r '.duration_ms // 0' "$out")"
  turns="$(jq -r '.num_turns // 0' "$out")"

  if ! aif_runner_claude_result_ok "$out"; then
    local reason
    reason="$(aif_runner_claude_result_error "$out")"
    aif_ledger_append "$work" "$(jq -n --arg s "$station" --argjson a "$attempt" \
      --arg m "$model" --argjson u "$usage" --argjson d "$dur" --argjson t "$turns" \
      --arg r "$reason" \
      '{ station: $s, attempt: $a, model: $m, usage: $u, duration_ms: $d,
         num_turns: $t, result: "error", reason: $r }')"
    rm -f "$out" "$err"
    aif_die "station failed: $reason"
  fi

  local out_hash="" outputs="[]"
  if [ -n "$produces" ]; then
    local artifact="$work/$produces"
    [ -f "$artifact" ] || aif_die "station reported success but did not write $produces"
    out_hash="$(aif_sha256 "$artifact")"
    outputs="$(jq -n --arg path "$produces" --arg sha "$out_hash" \
      '[ { path: $path, sha256: $sha } ]')"
  fi

  aif_ledger_append "$work" "$(jq -n \
    --arg s "$station" --argjson a "$attempt" --arg m "$model" \
    --argjson u "$usage" --argjson cost "$reported" \
    --argjson d "$dur" --argjson t "$turns" --argjson outputs "$outputs" \
    '{ station: $s, attempt: $a, model: $m,
       usage: $u,
       reported_cost_usd: $cost,
       cost_source: (if $cost > 0 then "reported" else "tokens-only" end),
       duration_ms: $d, num_turns: $t,
       outputs: $outputs }')"
  rm -f "$out" "$err"

  printf '%sran%s %s (attempt %s, %s output tokens)\n' \
    "$AIF_C_GREEN" "$AIF_C_RESET" "$station" "$attempt" \
    "$(printf '%s' "$usage" | jq -r '.output_tokens')"

  # The form gate runs immediately: a station's output is only worth anything if
  # it is admissible, and the sooner the reject the cheaper the retry.
  if [ -n "$form_gate" ]; then
    local gp="$root/.aif/gates/$form_gate.sh" gout grc=0
    if [ -f "$gp" ]; then
      gout="$(/bin/bash "$gp" "$work" 2>&1)" || grc=$?

      # Record the gate against the artifact it froze, when it names one, so the
      # next station's precondition can bind to it — otherwise against what the
      # station produced.
      local gate_subject="$produces" gate_hash="$out_hash"
      if [ -n "$freezes" ] && [ -f "$work/$freezes" ]; then
        gate_subject="$freezes"
        gate_hash="$(aif_sha256 "$work/$freezes")"
      fi

      aif_ledger_gate "$work" "$form_gate" \
        "$([ "$grc" -eq 0 ] && echo pass || echo fail)" \
        "$gate_subject" "$gate_hash" "$(aif_sha256 "$gp")" \
        "$(printf '%s' "$gout" | head -1)"
      if [ "$grc" -ne 0 ]; then
        aif_err "$form_gate rejected the output:"
        printf '%s\n' "$gout" | sed 's/^/  /' >&2
        return 1
      fi
      printf '%s✓%s %s\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$(printf '%s' "$gout" | head -1)"
    fi
  fi
}

aif_cmd_station() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift

  case "$sub" in
    run)
      local station="" ticket="" profile=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --profile)
            shift
            profile="${1:-}"
            ;;
          -*) aif_die "unknown option: $1" ;;
          *)
            if [ -z "$station" ]; then
              station="$1"
            else
              ticket="$1"
            fi
            ;;
        esac
        shift
      done
      local root
      root="$(aif_require_project)"
      _aif_station_run "$root" "$station" "$ticket" "$profile"
      ;;
    -h | --help | "")
      _aif_station_usage
      ;;
    *)
      aif_die "unknown subcommand: $sub"
      ;;
  esac
}
