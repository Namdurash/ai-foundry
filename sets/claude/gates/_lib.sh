#!/usr/bin/env bash
#
# Shared helpers for gate scripts.
#
# Gates run in CI from a fresh checkout, where `aif` is not installed, so this
# file deliberately duplicates a little of lib/common.sh rather than sourcing
# it. A gate that needs the tool that installed it is not a gate on the
# artifact, it is a gate on the toolchain.
#
# Targets bash 3.2: no associative arrays, no ${var,,}, no mapfile.

# Exit codes are the contract, and the 1/3 split drives the state machine:
#   0  the artifact passes
#   1  the artifact is rejected — fix it and retry
#   3  the gate could not run — stop looping, something upstream is broken
#
# AIF_G_PASS is documentation for whoever writes the next gate; nothing exits
# with a variable when the answer is a plain 0.
# shellcheck disable=SC2034
AIF_G_PASS=0
AIF_G_REJECT=1
AIF_G_ERROR=3

aif_g_reject() {
  printf 'REJECT %s\n' "$*" >&2
  exit "$AIF_G_REJECT"
}

aif_g_error() {
  printf 'ERROR  %s\n' "$*" >&2
  exit "$AIF_G_ERROR"
}

aif_g_need() {
  command -v "$1" >/dev/null 2>&1 || aif_g_error "required tool not found: $1"
}

# aif_g_have <command> — true if present. Gates cannot use lib/common.sh's
# aif_have (they run in CI without aif), and a call to a missing function fails
# silently under set +e — which is how an optional tool check turns into a quiet
# downgrade. Use this for optional tools like python3.
aif_g_have() {
  command -v "$1" >/dev/null 2>&1
}

aif_g_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | cut -d' ' -f1
  else
    aif_g_error "no sha256 tool (shasum or sha256sum)"
  fi
}

# aif_g_meta <file> — the JSON out of the FIRST aif:meta HTML comment.
#
# The metadata lives inside the markdown rather than beside it so that one
# artifact has exactly one hash. An HTML comment keeps it invisible wherever
# markdown is rendered.
#
# Only the first block: an artifact body may quote the format, and matching
# every block would concatenate them into invalid JSON. Kept identical to
# aif_meta_json in lib/common.sh.
aif_g_meta() {
  awk '
    /^<!-- aif:meta$/ && !seen { inblock = 1; seen = 1; next }
    inblock && /^-->$/         { inblock = 0; next }
    inblock                    { print }
  ' "$1"
}

# aif_g_meta_or_die <file> <label> — extract and validate in one step, since
# every caller wants both and a bad parse must be an ERROR (the gate cannot
# run), never a REJECT.
aif_g_meta_or_die() {
  local file="$1" label="$2"
  local meta

  [ -f "$file" ] || aif_g_reject "$label: file not found: $file"
  [ -s "$file" ] || aif_g_reject "$label: file is empty: $file"

  meta="$(aif_g_meta "$file")"
  if [ -z "$meta" ]; then
    aif_g_reject "$label: no <!-- aif:meta ... --> block"
  fi

  # Report the parse error verbatim. A retry is only productive if the model is
  # told which line broke.
  if ! printf '%s' "$meta" | jq -e . >/dev/null 2>&1; then
    printf 'REJECT %s: meta block is not valid JSON\n' "$label" >&2
    printf '%s' "$meta" | jq . 2>&1 | head -3 >&2
    exit "$AIF_G_REJECT"
  fi

  printf '%s' "$meta"
}

# aif_g_surface_drift <plan-meta> <spec-meta> — echo "AC<TAB>surface<TAB>detail"
# for every criterion whose file coverage disagrees with the file set its own
# surface claims.
#
# A heuristic, and it is written here once because two gates need the SAME
# answer: plan-form prints it, plan-judge requires it adjudicated. Recomputed
# from the artifacts on both sides rather than passed in a file, so there is
# nothing to go stale and nothing under tasks/ for a live gate to dirty.
#
# What it is looking for: four criteria on one live ticket declared the same
# surface and were mapped to three different file sets. The narrowest of them
# said "when bootstrap completes, the key is 32 bytes"; the plan narrowed it to
# the key-generation file alone, so the test called the generator directly and
# bootstrap never ran — pinning a standalone function in the test runtime, which
# is the one environment where the missing global happened to exist.
#
# NOT a proof and never a rejection on its own. A narrower coverage is often
# correct; this says only that the plan said two things about one surface.
aif_g_surface_drift() {
  local plan_meta="$1" spec_meta="$2"
  printf '%s' "$spec_meta" | jq -r --argjson plan "$(printf '%s' "$plan_meta" | jq -c .)" '
    def missing($a; $b): [ $a[]? | select(. as $x | ($b | index($x)) == null) ];
    ($plan.surface_map // {}) as $smap
    | ($plan.ac_coverage // {}) as $cov
    | .acceptance[]?
    | . as $ac
    | ($ac.surface // "") as $s
    | ($smap[$s] // []) as $m
    | ($cov[$ac.id] // []) as $c
    | missing($c; $m) as $extra
    | missing($m; $c) as $narrow
    | select(($extra | length) > 0 or ($narrow | length) > 0)
    | $ac.id + "\t" + $s + "\t"
      + ( [ (if ($narrow | length) > 0
              then "narrower than its surface by " + ($narrow | join(", ")) else empty end),
            (if ($extra | length) > 0
              then "covers " + ($extra | join(", ")) + ", which the surface map does not list"
              else empty end) ] | join("; ") )
  ' 2>/dev/null
}

# aif_g_external_gaps <plan-meta> — echo the name of every declared external
# dependency that names neither a check nor a criterion.
#
# The question is not "prove this claim is true" — a model that invented a method
# name will just as readily write "verified" beside it, and a judge that sees
# "verified" relaxes. The question is "what validates this?", which is a
# set-coverage question with exactly the shape of the uncovered-files check:
# a file with no criterion is a dependency with no validator.
aif_g_external_gaps() {
  printf '%s' "$1" | jq -r '
    .external[]?
    | select((.check // null) == null and (.ac // null) == null)
    | .name' 2>/dev/null
}

# aif_g_project <work-dir> — path to project.json, walking up from the work dir.
#
# Gates are handed a work dir but their configuration lives at the project root,
# and neither the depth of tasks/<ticket>/ nor the caller's cwd is guaranteed.
# Walking up rather than hopping a fixed number of levels is what let the work
# dir move out of .aif/ without touching this function.
aif_g_project() {
  local dir
  dir="$(cd "$1" 2>/dev/null && pwd -P)" || aif_g_error "no such work dir: $1"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/.aif/project.json" ]; then
      printf '%s' "$dir/.aif/project.json"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  aif_g_error ".aif/project.json not found — run 'aif project init'"
}

# aif_g_checks_run <project> <root> <phase> <record> — run the project's checks
# for one phase. Echoes one violation per line (empty = nothing required
# failed), and writes <record>: a JSON array of every check that ran, so a
# failure is attributable to a named check rather than to "the station".
#
# This is the rest of the Definition of Done. Before it, `green` read exactly
# one thing — `.test.command` — so a project whose DoD included a type-check or
# a lint pass could not express that, and therefore never enforced it. On the
# ticket that produced this gate, both were green, and that was established by a
# human during review rather than by the pipeline.
#
# aif learns nothing about what any command means. It learns that the project
# named some commands, which phase each belongs to, and whether a failure is
# fatal. The knowledge stays on the project side, where it belongs.
aif_g_checks_run() {
  local project="$1" root="$2" phase="$3" record="$4"
  local name cmd required rc out n=0 rows="" viol="" tab
  tab="$(printf '\t')"

  : >"$record"

  # No checks for this phase is the common case and must cost nothing.
  if [ "$(jq --arg p "$phase" \
    '[.checks[]? | select((.phase // []) | index($p))] | length' "$project" 2>/dev/null)" \
    = "0" ]; then
    printf '[]' >"$record"
    return 0
  fi

  while IFS="$tab" read -r name cmd required; do
    [ -n "$name" ] || continue
    n=$((n + 1))
    out="$(mktemp "${TMPDIR:-/tmp}/aif-check-XXXXXX")"
    rc=0
    (cd "$root" && eval "$cmd") >"$out" 2>&1 || rc=$?
    rows="$rows$name$tab$rc$tab$required$tab$(tail -3 "$out" | tr '\n\t' '  ')
"
    if [ "$rc" -ne 0 ]; then
      if [ "$required" = "true" ]; then
        viol="$viol
check \"$name\" failed (exit $rc): $(tail -1 "$out" | tr -d '\r')"
      else
        printf 'warn: optional check "%s" failed (exit %s) — recorded, not blocking\n' \
          "$name" "$rc" >&2
      fi
    fi
    rm -f "$out"
  done <<EOF
$(jq -r --arg p "$phase" '.checks[]?
  | select((.phase // []) | index($p))
  | [ .name, .command, (if .required == false then "false" else "true" end) ]
  | @tsv' "$project")
EOF

  jq -n --arg phase "$phase" --rawfile raw <(printf '%s' "$rows") '
    $raw | split("\n") | map(select(length > 0) | split("\t"))
    | map({ phase: $phase, name: .[0], exit: (.[1] | tonumber),
            required: (.[2] == "true"),
            result: (if .[1] == "0" then "pass" else "fail" end),
            tail: (.[3] // "") })' >"$record"

  printf '%s\n' "$viol" | sed '/^[[:space:]]*$/d'
}

# aif_g_report <violations> <label> — reject with a numbered list, or pass.
#
# Every violation is printed, never just the first. A gate that reports one
# problem per run turns a fix into a guessing game and burns a station attempt
# per line.
aif_g_report() {
  local violations="$1" label="$2"
  local count

  if [ -z "$violations" ]; then
    return 0
  fi

  count="$(printf '%s\n' "$violations" | grep -c .)"
  printf 'REJECT %s: %s problem(s)\n' "$label" "$count" >&2
  # Drop blank lines: an accumulator that prepends "\nMSG" leaves a leading
  # empty that would otherwise print as a bare bullet.
  printf '%s\n' "$violations" | sed '/^[[:space:]]*$/d; s/^/  - /' >&2
  exit "$AIF_G_REJECT"
}
