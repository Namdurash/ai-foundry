#!/usr/bin/env bash
#
# `aif _amend-plan <ticket> <path> <why>` — let an implementation widen the
# plan's file manifest, on the record.
# Sourced by bin/aif; not meant to be executed directly.
#
# The escape hatch for the case the plan could not foresee: an import pulls in a
# neighbouring module, a new handler has to be registered somewhere the plan
# never named. Without it the only outcomes are "scope rejects correct work" or
# "go back and re-plan", and the second costs a full planning round for one line.
#
# It writes plan-amendments.json, NOT plan.md, and that is not tidiness. tests.lock
# binds to plan.md's bytes; amending the plan itself would invalidate the frozen
# tests, so green would then reject the very implementation the amendment was
# meant to permit. A separate file leaves every existing binding intact.
#
# Three things keep this from being "the implementer may do as it likes":
#   - every amendment carries a reason and lands in a committed file a reviewer
#     reads, next to the plan it widens;
#   - it is capped (limits.plan_amendments_max). Past the cap the honest answer
#     is that the plan was wrong, and the ticket goes back to planning;
#   - scope prints the amendments in its verdict, so a widened manifest is never
#     a silent one.

AIF_AMEND_FILE="plan-amendments.json"

# aif_amend_paths <work> — the amended paths, one per line, empty if none or if
# the file is bound to a different plan.
#
# Also used by cmd_gate. Bound to plan.md's hash on purpose: edit the plan and
# the amendments lapse with it, exactly like every other binding here.
aif_amend_paths() {
  local work="$1" f="$1/$AIF_AMEND_FILE"
  [ -f "$f" ] || return 0
  [ -f "$work/plan.md" ] || return 0
  local bound
  bound="$(jq -r '.plan_sha256 // ""' "$f" 2>/dev/null)"
  [ "$bound" = "$(aif_sha256 "$work/plan.md")" ] || return 0
  jq -r '.amendments[]?.path // empty' "$f" 2>/dev/null
}

aif_cmd_amend_plan() {
  local ticket="${1:-}" path="${2:-}" why="${3:-}"
  [ -n "$ticket" ] && [ -n "$path" ] && [ -n "$why" ] ||
    aif_die "usage: aif _amend-plan <ticket> <path> <why>"

  local root work plan f project
  root="$(aif_require_project)"
  work="$(aif_task_dir "$root" "$ticket")"
  plan="$work/plan.md"
  f="$work/$AIF_AMEND_FILE"
  project="$(aif_project_config "$root")"

  [ -f "$plan" ] || aif_die "no plan.md for $ticket — there is no manifest to amend"

  # Normalise to a repo-relative path; a caller may hand us either form.
  case "$path" in
    "$root"/*) path="${path#"$root"/}" ;;
  esac

  # The paths an amendment may never reach. These are not "the plan did not
  # foresee it" cases, they are cases where the answer is a different station or
  # no station at all — so widening the manifest is the wrong move by definition.
  case "$path" in
    tasks/* | .aif/* | .claude/* | .github/*)
      aif_die "refusing to amend for '$path': that is the pipeline's own machinery, not implementation. No implementation may edit it, whatever the plan says."
      ;;
    tests/* | test/* | */tests/* | */test/* | *_test.* | *test_*.py | *.test.* | *.spec.*)
      aif_die "refusing to amend for '$path': the tests are frozen by verify-red. If a test is wrong, stop and report it — the ticket returns to have its tests or spec revised."
      ;;
  esac

  local plan_meta plan_hash
  plan_meta="$(aif_meta_json "$plan")"
  plan_hash="$(aif_sha256 "$plan")"

  if printf '%s' "$plan_meta" |
    jq -e --arg p "$path" '((.files.create // []) + (.files.change // [])) | index($p)' >/dev/null 2>&1; then
    aif_die "'$path' is already in the plan's manifest — nothing to amend"
  fi

  # A path that does not exist is a plan for an imagined repository, which is the
  # same defect plan-form catches for files.change. Creating NEW files is what
  # files.create is for and belongs in the plan, not here.
  [ -e "$root/$path" ] ||
    aif_die "'$path' does not exist. An amendment widens the manifest to a file the implementation must EDIT; a file that has to be created belongs in the plan's files.create, which means re-planning."

  # Start fresh whenever the binding does not match: an amendments file left over
  # from a previous plan is not this plan's, and carrying it forward would let a
  # re-planned ticket inherit permissions nobody granted it.
  if [ ! -f "$f" ] || [ "$(jq -r '.plan_sha256 // ""' "$f" 2>/dev/null)" != "$plan_hash" ]; then
    jq -n --arg h "$plan_hash" '{ schema: 1, plan_sha256: $h, amendments: [] }' >"$f.tmp" &&
      mv "$f.tmp" "$f"
  fi

  local cap count
  cap="$(jq -r '.limits.plan_amendments_max // 3' "$project" 2>/dev/null)"
  count="$(jq '.amendments | length' "$f")"
  if [ "$count" -ge "$cap" ]; then
    aif_err "the plan has already been amended $count time(s), and the cap is $cap."
    aif_die "Past this the plan is not being widened, it is being replaced — and that is a planning decision, not an implementation one. Stop and report what the plan got wrong."
  fi

  jq --arg p "$path" --arg w "$why" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '.amendments += [ { path: $p, why: $w, at: $at } ]' "$f" >"$f.tmp" && mv "$f.tmp" "$f"

  printf '%samended%s the manifest: %s\n  %s\n' \
    "$AIF_C_YELLOW" "$AIF_C_RESET" "$path" "$why"
  printf '  %s%s of %s used. It is recorded and a reviewer will see it next to the plan.%s\n' \
    "$AIF_C_DIM" "$((count + 1))" "$cap" "$AIF_C_RESET"
}
