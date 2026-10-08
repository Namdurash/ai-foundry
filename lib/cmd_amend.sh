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
# It writes plan-amendments.json, NOT plan.md, and that is not tidiness. tests.lock.json
# binds to plan.md's bytes; amending the plan itself would invalidate the frozen
# tests, so green would then reject the very implementation the amendment was
# meant to permit. A separate file leaves every existing binding intact.
#
# Three things keep this from being "the implementer may do as it likes":
#   - every amendment carries a reason and lands in a committed file a reviewer
#     reads, next to the plan it widens;
#   - it is capped (limits.plan_amendments_max). Past the cap the honest answer
#     is that the plan was wrong: the refusal names the bounded way back — a
#     replan, written in the implementer's note;
#   - scope prints the amendments in its verdict, so a widened manifest is never
#     a silent one — a file an amendment created marked (new).
#
# An amendment may create a file, beside the plan's own (docs/DEFECTS.md
# 13.10): a CSS module or a type file next to the component the plan creates
# is ordinary, and a new file used to be a replan — one per ticket — for a
# line. What a new path may be is decided by place and name, not extension:
# in a directory that holds a files.create or files.change path, never the
# root; not a dotfile; not a test; not a manifest or a lockfile; not the
# pipeline's or CI's. Recorded as `kind: "create"`; the cap counts both kinds.

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
  # CI and the ignore rules change only when the PLAN names them, the rule a
  # lockfile keeps (the gates' AIF_G_PLANNED_ONLY; docs/DEFECTS.md 13.10).
  case "$path" in
    tasks/* | .aif/* | .claude/* | project.json)
      aif_die "refusing to amend for '$path': that is the pipeline's own machinery, not implementation. No implementation may edit it, whatever the plan says."
      ;;
    .github/* | .gitlab-ci* | .gitignore)
      aif_die "refusing to amend for '$path': CI and the ignore rules change only when the plan names them — a ticket that needs one is re-planned with it in the manifest; say so in your note: { \"replan\": \"…\" } in tasks/$ticket/implement.note.json."
      ;;
    tests/* | test/* | __tests__/* | */tests/* | */test/* | */__tests__/* | *_test.* | *test_*.py | *.test.* | *.spec.*)
      aif_die "refusing to amend for '$path': the tests are frozen by verify-red. If a test is wrong, stop and report it — the ticket returns to have its tests or spec revised."
      ;;
    # A lockfile moves only with its manifest, and only when the PLAN named
    # both: a dependency is a planning decision, and the plan gate is where the
    # pair is checked (docs/DEFECTS.md 6.3). scope permits no amended lockfile
    # either; this says so before anything is written.
    package-lock.json | */package-lock.json | npm-shrinkwrap.json | */npm-shrinkwrap.json | \
      yarn.lock | */yarn.lock | pnpm-lock.yaml | */pnpm-lock.yaml | poetry.lock | */poetry.lock | \
      uv.lock | */uv.lock | Cargo.lock | */Cargo.lock | go.sum | */go.sum)
      aif_die "refusing to amend for '$path': a lockfile changes only when the plan names it together with its manifest. A dependency the plan did not foresee is a planning decision — stop and say so."
      ;;
  esac

  local plan_meta plan_hash
  plan_meta="$(aif_meta_json "$plan")"
  plan_hash="$(aif_sha256 "$plan")"

  if printf '%s' "$plan_meta" |
    jq -e --arg p "$path" '((.files.create // []) + (.files.change // [])) | index($p)' >/dev/null 2>&1; then
    aif_die "'$path' is already in the plan's manifest — nothing to amend"
  fi

  # A path that does not exist is a file to CREATE, and that is the plan's
  # files.create — unless it sits beside the plan's own files and is ordinary
  # code: a module the component needs, a style or type file next to it
  # (docs/DEFECTS.md 13.10). Decided by place and name, never extension; what
  # is refused is said, with the way through.
  local kind=change dir base_name roots
  if [ ! -e "$root/$path" ]; then
    kind=create
    dir="$(dirname "$path")"
    base_name="${path##*/}"
    case "/$path" in
      */.*)
        aif_die "refusing to create '$path' by amendment: a dotfile (or one under a dot-directory) is configuration, not code beside the plan's — it belongs in the plan's files.create; say so in your note: { \"replan\": \"…\" } in tasks/$ticket/implement.note.json."
        ;;
    esac
    if [ "$dir" = "." ]; then
      aif_die "refusing to create '$path' by amendment: a new file at the root of the repository is not one beside the plan's — it belongs in the plan's files.create; say so in your note: { \"replan\": \"…\" } in tasks/$ticket/implement.note.json."
    fi
    roots="$(jq -r '.test.roots[]?' "$project" 2>/dev/null)"
    while IFS= read -r r; do
      r="${r%/}"
      [ -n "$r" ] || continue
      case "$path" in
        "$r"/*) aif_die "refusing to amend for '$path': it is under the test root $r, and the tests are frozen by verify-red." ;;
      esac
    done <<EOF
$roots
EOF
    case "$base_name" in
      package.json | pyproject.toml | Cargo.toml | go.mod)
        aif_die "refusing to create '$path' by amendment: a dependency manifest is the plan's decision, with its lockfile — say so in your note: { \"replan\": \"…\" } in tasks/$ticket/implement.note.json."
        ;;
    esac
    if ! printf '%s' "$plan_meta" | jq -e --arg d "$dir" '
        ((.files.create // []) + (.files.change // []))
        | map(if test("/") then sub("/[^/]*$"; "") else "." end) | index($d) != null' >/dev/null 2>&1; then
      aif_die "refusing to create '$path' by amendment: $dir/ holds none of the plan's files.create or files.change — a new file goes beside the files the plan names, or into the plan itself; say so in your note: { \"replan\": \"…\" } in tasks/$ticket/implement.note.json."
    fi
  fi

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
    # The bounded way back named, not "stop": a replan, which the worker reads
    # from the note and runs once per ticket (docs/DEFECTS.md 13.10).
    aif_die "Past this the plan is not being widened, it is being replaced — a planning decision, not an implementation one. Write it in your note: { \"replan\": \"<what the plan got wrong>\" } in tasks/$ticket/implement.note.json, and finish; the worker hands it to the plan station."
  fi

  jq --arg p "$path" --arg w "$why" --arg k "$kind" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '.amendments += [ { path: $p, why: $w, kind: $k, at: $at } ]' "$f" >"$f.tmp" && mv "$f.tmp" "$f"

  printf '%samended%s the manifest: %s%s\n  %s\n' \
    "$AIF_C_YELLOW" "$AIF_C_RESET" "$path" "$([ "$kind" = create ] && printf ' (new — write it)')" "$why"
  printf '  %s%s of %s used. It is recorded and a reviewer will see it next to the plan.%s\n' \
    "$AIF_C_DIM" "$((count + 1))" "$cap" "$AIF_C_RESET"
}
