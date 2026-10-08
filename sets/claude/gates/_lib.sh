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

# Exit codes are the contract, and each one sends the worker somewhere else:
#   0  the artifact passes
#   1  the artifact is rejected — the station that wrote it fixes it and retries
#   2  the TICKET is the problem, not the artifact — a criterion already true,
#      unfalsifiable, in conflict, undecided. A spec stop: to the analyst, with
#      the gate's words, and no retry of anything (docs/REBUILD-4.md §2.1)
#   3  the gate could not render a verdict — the environment, or a defect no
#      loop in the stage can reach. Stop looping
#   4  the ORACLE is the problem, found at green: a frozen test the implement
#      station may not touch. Not a stop any more — the tests station repairs
#      it in a copy of the tree with the implementation reverted, under the
#      same gates that admitted the original (docs/REBUILD-4.md §2.3)
#
# AIF_G_PASS is documentation for whoever writes the next gate; nothing exits
# with a variable when the answer is a plain 0.
# shellcheck disable=SC2034
AIF_G_PASS=0
AIF_G_REJECT=1
# This file's own directory — where junit.py sits beside it, for the helpers
# below that read a report a copy of the tree wrote.
AIF_G_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
AIF_G_SPEC=2
AIF_G_ERROR=3
AIF_G_REPAIR=4

# The marker a skeleton throws. The plan station writes every new export as a
# signature whose body throws exactly this, so a test of this ticket is red
# for one of two reasons only: an assertion failed, or the behaviour is not
# built yet. Anything else a new test fails with is the test's own defect —
# a name the contract does not export, a fixture that does not exist — and it
# is caught before the freeze instead of three attempts after it.
# shellcheck disable=SC2034
AIF_G_NOT_IMPLEMENTED='aif: not implemented'

# Paths no implementation may touch, whatever the plan says: the pipeline's own
# machinery. Anchored so they match from the repo root only.
#
# ONE list, TWO gates, and that is the point of it living here. The plan gate
# rejects a manifest path matching it at plan time, where the fix costs a
# re-plan; scope holds the same line against the diff after the code exists, as
# the backstop. When the two lists were one gate's private constant they
# disagreed: a plan named yarn.lock in files.change, both plan gates accepted
# it, and scope would then have rejected the implementation for doing exactly
# what the approved plan permitted.
#
# What is on it is how a ticket is judged and recorded: the gates (.aif/gates),
# the test command, checks, failure classes and caps (.aif/project.json), the
# guard and its registration (.aif/hooks, .claude/settings.json), the stations'
# instructions (.claude/agents), and the tickets' own records (tasks/). A
# ticket that could edit them could change how it is judged — and the land
# settles a conflict there by taking the checkout's side (lib/integrate.sh), so
# a ticket's edit there could vanish without a word (docs/DEFECTS.md 13.10).
# shellcheck disable=SC2034
AIF_G_DENYLIST='^\.aif/|^tasks/|^\.claude/|^project\.json$'

# Paths an implementation changes only when the PLAN names them: CI and the
# ignore rules. They used to sit on the denylist, and a ticket whose work was a
# workflow or an ignore line could not be planned at all (docs/DEFECTS.md
# 13.10). The plan gate admits them in files.create, .change and .delete and
# prints them on its pass path; scope passes them only when the plan names
# them — never through an amendment, the rule a lockfile keeps — and prints
# what a planned .gitignore now ignores, because scope's own diff reads the
# untracked files through it (--exclude-standard) and a newly ignored file
# would otherwise leave the diff in silence.
# shellcheck disable=SC2034
AIF_G_PLANNED_ONLY='^\.github/|^\.gitlab-ci|^\.gitignore$'

# Dependency manifests, and the lockfiles that pin what they ask for.
#
# The lockfiles used to sit on the denylist, "until a sanctioned route for
# dependency changes is answered". The manifests never did — and that half-open
# door is how a dependency got into a ticket's worktree around its lock: the
# plan named package.json, the lockfile could not be named, and a station
# installed the package without it. npm then re-resolved packages nobody had
# asked to move, into an incompatible pair, and twelve pre-existing tests went
# red where no diff to the manifest could reach them (docs/DEFECTS.md 6.3).
#
# The route is now this: a manifest and its lockfile change TOGETHER or not at
# all. The plan gate requires the lockfile whenever the plan names the
# manifest, and refuses a lockfile named without its manifest; scope permits a
# lockfile only when the plan names it; `aif _amend-plan` refuses lockfiles,
# because a new dependency is the plan's decision; and the worker re-runs
# "prepare" from the lock after a station changes either, so the gates judge
# the dependencies the lockfile builds rather than whatever a station
# installed. lib/cmd_work.sh keeps a copy of these two for that last step
# (it cannot source this file); scripts/check-work.sh holds the copies equal.
# shellcheck disable=SC2034
AIF_G_MANIFESTS='(^|/)(package\.json|pyproject\.toml|Cargo\.toml|go\.mod)$'
# shellcheck disable=SC2034
AIF_G_LOCKFILES='(^|/)(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|poetry\.lock|uv\.lock|Cargo\.lock|go\.sum)$'

# aif_g_lock_names <manifest-basename> — the lockfile names that can pin it,
# one per line. The table behind both patterns above.
aif_g_lock_names() {
  case "$1" in
    package.json) printf '%s\n' package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml ;;
    pyproject.toml) printf '%s\n' poetry.lock uv.lock ;;
    Cargo.toml) printf '%s\n' Cargo.lock ;;
    go.mod) printf '%s\n' go.sum ;;
  esac
}

# aif_g_lockfiles_for <root> <manifest> — the lockfiles that pin this manifest
# as the repository stands, one repo-relative path per line; empty when none
# exists. The nearest directory that has one wins, walking up from the
# manifest's own: a workspace package's package.json is pinned by the lockfile
# at the workspace root.
aif_g_lockfiles_for() {
  local root="$1" manifest="$2" names dir n p found
  names="$(aif_g_lock_names "$(basename "$manifest")")"
  [ -n "$names" ] || return 0
  dir="$(dirname "$manifest")"
  while :; do
    found=""
    for n in $names; do
      if [ "$dir" = "." ]; then p="$n"; else p="$dir/$n"; fi
      [ ! -f "$root/$p" ] || found="$found$p
"
    done
    if [ -n "$found" ]; then
      printf '%s' "$found"
      return 0
    fi
    [ "$dir" != "." ] || return 0
    dir="$(dirname "$dir")"
  done
}

# aif_g_locks <lockfile> <manifest> — rc 0 when this lockfile can pin this
# manifest: a name from its family, in its directory or one above it.
aif_g_locks() {
  local lock="$1" manifest="$2" n ok=1 ldir mdir
  for n in $(aif_g_lock_names "$(basename "$manifest")"); do
    [ "$n" != "$(basename "$lock")" ] || ok=0
  done
  [ "$ok" -eq 0 ] || return 1
  ldir="$(dirname "$lock")"
  mdir="$(dirname "$manifest")"
  while :; do
    [ "$mdir" != "$ldir" ] || return 0
    [ "$mdir" != "." ] || return 1
    mdir="$(dirname "$mdir")"
  done
}

# aif_g_test_path <path> [<roots>] — rc 0 when <path> is a test file: under one
# of the project's test roots (one a line), under a tests/, test/ or __tests__/
# directory, or named like one — *.test.*, *.spec.*, *_test.*, test_*.py. One
# rule for the gates that ask: the plan gate (what files.delete may not name,
# where a replaced criterion's tests are looked for) and verify-red. The guard
# keeps a copy (hooks cannot source the gates); `__tests__/` is the jest
# template's own root, which the guard's copy missed (docs/DEFECTS.md 13.10).
aif_g_test_path() {
  local p="$1" r b
  while IFS= read -r r; do
    r="${r%/}"
    [ -n "$r" ] || continue
    case "$p" in
      "$r"/*) return 0 ;;
    esac
  done <<EOF
${2:-}
EOF
  case "$p" in
    tests/* | test/* | __tests__/* | */tests/* | */test/* | */__tests__/*) return 0 ;;
  esac
  b="${p##*/}"
  case "$b" in
    *.test.* | *.spec.* | *_test.* | test_*.py) return 0 ;;
  esac
  return 1
}

# aif_g_marker_in <normalised-id> <normalised-marker> — rc 0 when the id
# carries the marker as a whole: `AIF-69 AC-001` in `AIF-69 AC-001 t3` and in
# test_aif_69_ac_001_x, never in AIF-690, AC-0010 or XAIF-69. Both sides are
# aif_g_norm's, where every run of what is not a letter or a digit is one
# underscore, so an underscore on each side is the word's edge.
aif_g_marker_in() {
  case "_$1_" in
    *"_$2_"*) return 0 ;;
  esac
  return 1
}

# aif_g_marker_re <marker> — the same whole-word match over a file's text, as an
# extended regex for `grep -i -E`: `AIF-69 AC-001` becomes
# (^|[^a-z0-9])aif[^a-z0-9]+69[^a-z0-9]+ac[^a-z0-9]+001([^0-9]|$) — a jest title
# and a pytest function name both match it (docs/FINDINGS.md #36).
aif_g_marker_re() {
  printf '(^|[^a-z0-9])%s([^0-9]|$)' \
    "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\{1,\}/[^a-z0-9]+/g')"
}

# aif_g_replaced_markers <work> — the criteria of other tickets this ticket's
# rules replace, one `<OLD> AC-nnn<TAB><R-n><TAB><the changes entry>` a line.
#
# A rule names what it replaces in `changes` — `<OLD> R-n`, every criterion of
# <OLD> that names R-n, or `<OLD> AC-nnn` itself — the resolution the ready
# gate and `aif rules` make (docs/DEFECTS.md 12.2). The tests carrying those
# criteria assert what this ticket ends: the plan must declare their files,
# and verify-red refuses one still collected (docs/DEFECTS.md 12.3). Read from
# the older ticket's own file beside this one under tasks/.
aif_g_replaced_markers() {
  local work="$1" tasks tab rid ref other item ac
  [ -f "$work/ticket.md" ] || return 0
  tasks="$(dirname "$work")"
  tab="$(printf '\t')"
  aif_g_meta "$work/ticket.md" | jq -r '
    .rules? | arrays | .[] | objects | (.id // "?") as $r
    | (.changes? | arrays | .[]) | strings
    | select(test("^[^ ]+ (R-[0-9]+|AC-[0-9]{3})$")) | $r + "\t" + .' 2>/dev/null |
    while IFS="$tab" read -r rid ref; do
      [ -n "$ref" ] || continue
      other="${ref%% *}"
      item="${ref#* }"
      case "$item" in
        AC-*) printf '%s\t%s\t%s\n' "$ref" "$rid" "$ref" ;;
        *)
          [ -f "$tasks/$other/ticket.md" ] || continue
          aif_g_meta "$tasks/$other/ticket.md" | jq -r --arg r "$item" \
            '.acceptance? | arrays | .[] | objects | select(.rule == $r) | .id // empty' 2>/dev/null |
            while IFS= read -r ac; do
              [ -n "$ac" ] || continue
              printf '%s %s\t%s\t%s\n' "$other" "$ac" "$rid" "$ref"
            done
          ;;
      esac
    done
  return 0
}

# aif_g_changed_since <root> <base> — every path the working tree changed since
# <base>: tracked edits and deletions, and new files git does not ignore. One
# repo-relative path per line — the same diff scope reads.
aif_g_changed_since() {
  {
    git -C "$1" -c core.quotePath=false diff --name-only "$2" 2>/dev/null
    git -C "$1" -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null
  } | sort -u
}

# aif_g_dep_changes <root> <base> — the dependency manifests and lockfiles
# among them.
aif_g_dep_changes() {
  aif_g_changed_since "$1" "$2" | grep -E "$AIF_G_MANIFESTS|$AIF_G_LOCKFILES" || true
}

aif_g_reject() {
  printf 'REJECT %s\n' "$*" >&2
  exit "$AIF_G_REJECT"
}

aif_g_error() {
  printf 'ERROR  %s\n' "$*" >&2
  exit "$AIF_G_ERROR"
}

# aif_g_spec <lines> — the ticket, not the artifact: a spec stop. Every line
# is a question for the analyst, printed as the gates print problems.
aif_g_spec() {
  printf 'SPEC   the ticket, not the artifact — for the analyst:\n' >&2
  printf '%s\n' "$1" |
    sed '/^[[:space:]]*$/d; /^[[:space:]]/s/^/    /; /^[^[:space:]]/s/^/  - /' >&2
  exit "$AIF_G_SPEC"
}

# aif_g_norm <text> — a test id or a marker, normalised for matching: lower
# case, every run of non-alphanumerics one underscore. A jest name
# "OPES-69 AC-003 — titles the sheet" and a pytest function
# test_opes_69_ac_003_titles then both contain opes_69_ac_003, which is how a
# criterion's marker is looked for in a collected test's id rather than in a
# file's text, where a comment or another ticket's test would satisfy it.
aif_g_norm() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\{1,\}/_/g'
}

# aif_g_imports_unresolved <root> <file> — every relative import in a test
# file that resolves to nothing on disk, one "<specifier>" per line.
#
# The misspelled path is the one defect verify-red could never tell from a
# legitimate red: both are "cannot find module", and a misspelling was frozen
# as red and surfaced at green in a file nobody may edit by then. With the
# contract on disk before the tests are written, a relative import that
# resolves to no file IS a misspelling, and it is the tests station's to fix.
#
# Only the unambiguous cases: a JavaScript or TypeScript specifier that
# starts with "." (resolved with the runner's extensions and index files),
# and a python relative import ("from .x import", "from ..x import"). A bare
# package name, or a python absolute module, depends on a resolver or a
# sys.path this gate does not know, and is left alone.
aif_g_imports_unresolved() {
  local root="$1" file="$2" dir spec base cand found e
  dir="$(dirname "$file")"
  case "$file" in
    *.js | *.jsx | *.ts | *.tsx | *.mjs | *.cjs | *.mts | *.cts)
      # import … from './x'  ·  require('./x')  ·  import('./x')  ·  jest.mock('./x'
      # The first group is the specifier; a specifier that starts with a dot
      # is relative to the file.
      sed -n -E "s/.*(from|require|import|jest\.mock|vi\.mock|jest\.requireActual)[[:space:]]*\(?[[:space:]]*['\"](\.[^'\"]*)['\"].*/\2/p" "$file" |
        sort -u | while IFS= read -r spec; do
        [ -n "$spec" ] || continue
        base="$dir/$spec"
        found=0
        for cand in "$base" "$base.ts" "$base.tsx" "$base.js" "$base.jsx" "$base.mjs" "$base.cjs" \
          "$base.mts" "$base.cts" "$base.json" "$base.d.ts" \
          "$base/index.ts" "$base/index.tsx" "$base/index.js" "$base/index.jsx"; do
          if [ -f "$root/$cand" ]; then
            found=1
            break
          fi
        done
        [ "$found" -eq 1 ] || printf '%s\n' "$spec"
      done
      ;;
    *.py)
      # from .x import …  ·  from ..pkg.x import … — resolved against the
      # file's own package: one dot is this directory, each further dot one up.
      sed -n -E 's/^[[:space:]]*from[[:space:]]+(\.+)([A-Za-z0-9_.]*)[[:space:]]+import.*/\1 \2/p' "$file" |
        sort -u | while IFS=' ' read -r dots mod; do
        [ -n "$dots" ] || continue
        base="$dir"
        e="${#dots}"
        while [ "$e" -gt 1 ]; do
          base="$(dirname "$base")"
          e=$((e - 1))
        done
        if [ -n "$mod" ]; then
          base="$base/$(printf '%s' "$mod" | tr '.' '/')"
        fi
        if [ -f "$root/$base.py" ] || [ -f "$root/$base/__init__.py" ] || [ -d "$root/$base" ]; then
          continue
        fi
        printf '%s%s\n' "$dots" "$mod"
      done
      ;;
  esac
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
  # The CR is stripped before anything is matched. A card edited in a browser
  # can come back with \r\n, and a line that is `<!-- aif:meta\r` matches
  # nothing — the ticket then reads as "not written by the analyst", which
  # sends the human to the wrong place (docs/DEFECTS.md 3.10).
  awk '
    { sub(/\r$/, "") }
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

# aif_g_dispatch_base <work> <root> — the commit the implementation is judged
# against: HEAD as it was when the worker dispatched the station, or HEAD now.
#
# "The last commit" was the baseline for as long as these gates existed, and
# the implement station has Bash. One `git commit -am` from the station and
# `git diff HEAD` is empty: scope passed everything with "0 lines", and green
# reverted from an index that already held the implementation and blamed the
# tests for not depending on it (docs/DEFECTS.md 3.8). So the worker writes
# HEAD into the run record before every dispatch, and the gates read that. HEAD
# is the fallback for a gate run by hand, where there is no record and no
# station in between to have committed.
aif_g_dispatch_base() {
  local work="$1" root="$2" base
  base="$(jq -r '.dispatch_base // empty' "$work/run.json" 2>/dev/null)"
  if [ -n "$base" ] && git -C "$root" rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1; then
    printf '%s' "$base"
  else
    git -C "$root" rev-parse HEAD 2>/dev/null
  fi
}

# aif_g_ticket_base <work> <root> — the tree before this ticket: the commit
# the branch was last brought onto (run.json sync_base), else the one the plan
# station first saw (plan_base), else the one the run was cut from (base) —
# the first of them that is a commit — and the dispatch base when the record
# names none (a gate run by hand).
#
# It is not the tests station's dispatch base, which verify-red measured a
# failing pre-existing test against (docs/DEFECTS.md 6.1): that tree already
# holds the plan's skeleton and every constant the contract fixed, and a
# pre-existing test the contract broke reads there as red before — the
# repository's — when it is this ticket's doing (docs/DEFECTS.md 13.9).
aif_g_ticket_base() {
  local work="$1" root="$2" b
  for b in $(jq -r '(.sync_base // empty), (.plan_base // empty), (.base // empty)' "$work/run.json" 2>/dev/null); do
    if git -C "$root" rev-parse -q --verify "$b^{commit}" >/dev/null 2>&1; then
      printf '%s' "$b"
      return 0
    fi
  done
  aif_g_dispatch_base "$work" "$root"
}

# _aif_g_listed <line> <lines> — rc 0 when <line> is one of <lines>, whole.
_aif_g_listed() {
  case "
$2
" in
    *"
$1
"*) return 0 ;;
  esac
  return 1
}

# _aif_g_below <dir> <paths> — rc 0 when one of <paths> is under <dir>.
_aif_g_below() {
  case "
$2" in
    *"
$1/"*) return 0 ;;
  esac
  return 1
}

# _aif_g_within <path> <dirs> — rc 0 when <path> is one of <dirs> or under one.
_aif_g_within() {
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$1" in
      "$d" | "$d"/*) return 0 ;;
    esac
  done <<EOF
$2
EOF
  return 1
}

# aif_g_dep_dirs <root> — the installed dependencies a copy of the tree links
# rather than copies, one repo-relative directory a line: every node_modules,
# the first one down each branch of the tree, and .venv or venv at the root —
# each only while git ignores it. One `find`, pruned at each match and never
# into .git or .aif/worktrees; one `git check-ignore` for all of them. A
# node_modules someone force-added a file to reads as not ignored, and is
# copied with the rest (docs/FINDINGS.md #36).
aif_g_dep_dirs() {
  local root="$1" p
  {
    find "$root" \( -path "$root/.git" -o -path "$root/.aif/worktrees" \) -prune -o \
      -type d -name node_modules -print -prune 2>/dev/null
    for p in .venv venv; do
      if [ -d "$root/$p" ] && [ ! -L "$root/$p" ]; then printf '%s\n' "$root/$p"; fi
    done
  } | while IFS= read -r p; do
    p="${p#"$root"/}"
    [ -z "$p" ] || [ "$p" = "$root" ] || printf '%s\n' "$p"
  done | git -C "$root" check-ignore --stdin 2>/dev/null || true
}

# _aif_g_copy_into <src> <dst> <rel> <links> <walk> — the entries of
# <src>/<rel> into <dst>/<rel>: a directory in <links> as a symlink to the real
# one, one in <walk> — an ancestor of something linked or skipped — entered
# entry by entry, .aif/worktrees left behind, everything else `cp -R`, once.
# rc 1 with the reason on stderr, the copy cut short.
_aif_g_copy_into() {
  local src="$1" dst="$2" rel="$3" links="$4" walk="$5" p r d err
  for p in "$src${rel:+/$rel}"/* "$src${rel:+/$rel}"/.[!.]* "$src${rel:+/$rel}"/..?*; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    r="${p#"$src"/}"
    [ "$r" != ".aif/worktrees" ] || continue
    if _aif_g_listed "$r" "$links"; then
      ln -s "$p" "$dst/$r" 2>/dev/null || {
        printf 'could not link %s into the copy\n' "$r" >&2
        return 1
      }
    elif _aif_g_below "$r" "$walk"; then
      mkdir -p "$dst/$r" || return 1
      _aif_g_copy_into "$src" "$dst" "$r" "$links" "$walk" || return 1
    else
      d="$dst"
      case "$r" in */*) d="$dst/${r%/*}" ;; esac
      # Checked, and its own words kept: on macOS an unreadable file is rc 1
      # and the copy carries on without it — a suite then run in the copy
      # judges a tree with a file missing, which `|| true` hid. A socket is
      # rc 0, "is a socket (not copied)"; a FIFO is copied (#36).
      if ! err="$(cp -R "$p" "$d/" 2>&1)"; then
        printf 'could not copy %s: %s\n' "$r" "$(printf '%s' "$err" | grep -v 'is a socket (not copied)' | sed -n '1,4p' | paste -sd ';' -)" >&2
        return 1
      fi
    fi
  done
  return 0
}

# aif_g_scratch_at <root> <base> [<dir>] — a copy of the working tree as it
# stood at <base>, echoed: made in <dir> when one is named, else in a new
# temporary directory the caller removes. Every path the tree changed since
# that commit (see aif_g_changed_since) is put back to <base>'s content, or
# removed where <base> did not have it. What git ignores is copied as it
# stands, because that is what a suite runs against — except the installed
# dependencies (aif_g_dep_dirs), which are linked: a node_modules is most of a
# JavaScript tree, copied once per gate per run, side by side with every other
# worker's (docs/DEFECTS.md 13.9). A package that finds the project from its
# own location reads the real tree through the link — `__dirname` there is
# the real path (#36) — so AIF_G_COPY_DEPS=1 in the environment copies them
# as before. `rm -rf` of the copy removes a link, never what it points at.
#
# rc 1, the reason on stderr, when the copy could not be made whole — an
# unreadable file, a file the base could not give back: a suite judged in a
# copy with a file missing judges another tree, so the callers stop on it
# (exit 3) instead of reading what that tree says.
#
# .aif/worktrees/ is left behind: those are the worker's other checkouts,
# complete trees with their own installed dependencies, and nothing a suite
# here reads.
#
# Git is only ever asked READ-ONLY questions of the real repository here, and
# is never run inside the copy. A copy of a linked worktree carries its .git
# FILE, which points at the real worktree's gitdir: `git checkout <base> -- f`
# run in the copy restores the copy's file and stages <base>'s blob in the REAL
# worktree's index. green's revert-recheck did exactly that for as long as it
# existed (docs/DEFECTS.md 6.4).
aif_g_scratch_at() {
  local root="$1" base="$2" scratch="${3:-}" made=0 links="" walk p changed
  if [ -n "$scratch" ]; then
    mkdir -p "$scratch" || return 1
  else
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/aif-scratch-XXXXXX")" || return 1
    made=1
  fi
  # Resolved once, here. macOS's TMPDIR ends in "/", so mktemp hands back
  # ".../T//aif-scratch-…" — and a suite run after `cd` into it prints
  # ".../T/aif-scratch-…" (or /private/var/…), a spelling no comparison of the
  # two runs' output then recognises as the copy.
  scratch="$(cd "$scratch" && pwd -P)" || return 1
  [ "${AIF_G_COPY_DEPS:-0}" = 1 ] || links="$(aif_g_dep_dirs "$root")"
  # A directory is entered rather than copied whole when something under it
  # is linked, or left behind (.aif/worktrees): every line of <walk> below it.
  walk="$links"
  [ ! -d "$root/.aif/worktrees" ] || walk="$walk
.aif/worktrees"
  if ! _aif_g_copy_into "$root" "$scratch" "" "$links" "$walk"; then
    [ "$made" -eq 0 ] || rm -rf "${scratch:?}"
    return 1
  fi
  if [ -n "$base" ]; then
    changed="$(aif_g_changed_since "$root" "$base")"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      # Never through a link: what is under one is the real tree's.
      ! _aif_g_within "$p" "$links" || continue
      rm -rf "${scratch:?}/${p:?}" 2>/dev/null || true
      git -C "$root" cat-file -e "$base:$p" 2>/dev/null || continue
      if ! mkdir -p "$scratch/$(dirname "$p")" 2>/dev/null ||
        ! git -C "$root" show "$base:$p" >"$scratch/$p" 2>/dev/null; then
        printf 'could not put %s back as it was at %s\n' "$p" "$(printf '%s' "$base" | cut -c1-10)" >&2
        [ "$made" -eq 0 ] || rm -rf "${scratch:?}"
        return 1
      fi
    done <<EOF
$changed
EOF
  fi
  printf '%s' "$scratch"
}

# aif_g_base_key <root> <base> <command> — what a measurement at <base> is kept
# under: the commit, and the tracked lockfiles' bytes with the command, hashed
# — the same base under the same installed dependencies and the same command
# answers the same. What else git ignores (generated code, an .env) is not in
# the key (docs/FINDINGS.md #36).
aif_g_base_key() {
  local h f
  h="$({
    git -C "$1" -c core.quotePath=false ls-files 2>/dev/null | grep -E "$AIF_G_LOCKFILES" |
      while IFS= read -r f; do
        [ ! -f "$1/$f" ] || cat "$1/$f"
      done
    printf '%s' "$3"
  } | aif_g_sha256 /dev/stdin | cut -c1-12)"
  printf '%s-%s' "$2" "$h"
}

# aif_g_base_copy <root> <base> <dir> — <dir> holds the copy of the tree at
# <base> (aif_g_scratch_at): made the first time a gate needs it, once a run,
# and removed in that gate's EXIT trap with <dir>.at beside it.
aif_g_base_copy() {
  if [ -d "$3" ] && [ "$(cat "$3.at" 2>/dev/null)" = "$2" ]; then
    return 0
  fi
  rm -rf "${3:?}" "${3:?}.at"
  aif_g_scratch_at "$1" "$2" "$3" >/dev/null || return 1
  printf '%s' "$2" >"$3.at"
}

# aif_g_base_suite <project> <root> <base> <dir> — the suite before this
# ticket: the junit rows (junit.py's) of test.command run in a copy of the tree
# at <base>, printed. rc 0 · 1 it could not be measured there, the reason
# printed · 2 the copy could not be made, the reason printed (the caller's 3).
#
# Kept under .aif/tmp/base/ by aif_g_base_key: the station's own `aif _verify`
# loop, the gate that freezes, a repair's copy (which carries .aif/tmp) and the
# gates after them pay for one run per base and installed dependencies.
aif_g_base_suite() {
  local project="$1" root="$2" base="$3" dir="$4" cmd report key cache out json err
  cmd="$(jq -r '.test.command // empty' "$project" 2>/dev/null)"
  report="$(jq -r '.test.report.path // empty' "$project" 2>/dev/null)"
  if [ -z "$cmd" ] || [ -z "$report" ] || [ "$report" = null ]; then
    printf 'the project names no test command or no report path'
    return 1
  fi
  if ! aif_g_have python3; then
    printf 'python3 is not on PATH, and the report cannot be read per test'
    return 1
  fi
  key="$(aif_g_base_key "$root" "$base" "$cmd")"
  cache="$root/.aif/tmp/base"
  if [ -s "$cache/$key.suite.json" ]; then
    cat "$cache/$key.suite.json"
    return 0
  fi
  if ! err="$(aif_g_base_copy "$root" "$base" "$dir" 2>&1)"; then
    printf '%s' "$err"
    return 2
  fi
  mkdir -p "$dir/$(dirname "$report")" "$dir/.aif/tmp"
  rm -f "${dir:?}/${report:?}"
  out="$dir/.aif/tmp/base-suite.out"
  (cd "$dir" && eval "$cmd") </dev/null >"$out" 2>&1 || true
  if [ ! -f "$dir/$report" ]; then
    printf 'the suite wrote no report there — %s' "$(grep -v '^[[:space:]]*$' "$out" | tail -1 | cut -c1-160)"
    return 1
  fi
  json="$(python3 "$AIF_G_HERE/junit.py" "$dir/$report" 2>/dev/null)" || json=""
  if [ -z "$json" ]; then
    printf 'the report it wrote there could not be read'
    return 1
  fi
  if mkdir -p "$cache" 2>/dev/null && printf '%s' "$json" >"$cache/$key.suite.json.$$" 2>/dev/null; then
    mv "$cache/$key.suite.json.$$" "$cache/$key.suite.json" 2>/dev/null || rm -f "$cache/$key.suite.json.$$"
  fi
  printf '%s' "$json"
}

# aif_g_base_check <project> <root> <base> <name> <dir> — one check before this
# ticket: its command run in the copy at <base>, printed as
# "<exit><TAB><file of its lines>" — the lines with the copy's path folded to
# <root> (aif_g_lines), so a run kept from another copy compares. Kept as the
# suite is. rc 0 · 1 no such check · 2 the copy could not be made, the reason
# printed.
aif_g_base_check() {
  local project="$1" root="$2" base="$3" name="$4" dir="$5" cmd key f rc=0 err
  cmd="$(jq -r --arg n "$name" '[ .checks[]? | select(.name == $n) | .command ] | .[0] // empty' "$project" 2>/dev/null)"
  [ -n "$cmd" ] || return 1
  key="$(aif_g_base_key "$root" "$base" "$cmd")"
  f="$root/.aif/tmp/base/$key.check.$(aif_g_norm "$name")"
  if [ -f "$f.out" ] && [ -f "$f.rc" ]; then
    printf '%s\t%s' "$(cat "$f.rc")" "$f.out"
    return 0
  fi
  if ! err="$(aif_g_base_copy "$root" "$base" "$dir" 2>&1)"; then
    printf '%s' "$err"
    return 2
  fi
  mkdir -p "$root/.aif/tmp/base"
  (cd "$dir" && eval "$cmd") </dev/null >"$f.raw.$$" 2>&1 || rc=$?
  aif_g_lines "$f.raw.$$" "$dir" >"$f.out"
  rm -f "$f.raw.$$"
  printf '%s' "$rc" >"$f.rc"
  printf '%s\t%s' "$rc" "$f.out"
}

# aif_g_lines <file> <root> — the file's non-blank lines with colour codes and
# CRs stripped, and every spelling of <root> replaced by "<root>". The same
# output from two copies of one tree then compares equal line for line, which
# is how a failure is told apart from one the implementation added.
aif_g_lines() {
  local r1="$2" r2
  r2="$(cd "$r1" 2>/dev/null && pwd -P)" || r2="$r1"
  AIF_G_R1="$r1" AIF_G_R2="$r2" awk '
    function repl(s, from, to,   out, i) {
      if (from == "") return s
      out = ""
      while ((i = index(s, from)) > 0) {
        out = out substr(s, 1, i - 1) to
        s = substr(s, i + length(from))
      }
      return out s
    }
    BEGIN {
      a = ENVIRON["AIF_G_R1"]; b = ENVIRON["AIF_G_R2"]
      # The longer first: /private/var/x holds /var/x, and replacing the short
      # one inside it would leave "/private<root>".
      if (length(b) > length(a)) { t = a; a = b; b = t }
    }
    { sub(/\r$/, ""); gsub(/\033\[[0-9;]*m/, "") }
    /[^ \t]/ { print repl(repl($0, a, "<root>"), b, "<root>") }
  ' "$1"
}

# aif_g_new_lines <now> <now-root> <base-out> [<base-root>] — the lines of <now>
# in excess of <base-out>, as <now> printed them: a multiset, so a second
# TS2554 in a file that had one is new, and a line the base printed once
# answers for one line now.
#
# Compared the way aif_g_lines compares (colour, CRs, blank lines, each
# root's spellings as <root> — <base-out> may already be folded, and then has
# no root), and past it: positions — `(12,5)`, `:12:5`, a leading `12:5` —
# durations — `1.9s`, `120 ms` — and counts of errors, problems, warnings and
# files, all folded to `#`. A line whose number moved is the same line; "Done
# in 1.9s" is "Done in 2.31s"; "Found 3 errors" is "Found 2 errors", since a
# summary line moves with every fix and is not a failure of its own
# (docs/FINDINGS.md #36). What it cannot tell: a base error fixed and a new
# one with the same words in the same file net to nothing.
aif_g_new_lines() {
  local n1="$2" n2 b1="${4:-}" b2=""
  n2="$(cd "$n1" 2>/dev/null && pwd -P)" || n2="$n1"
  if [ -n "$b1" ]; then
    b2="$(cd "$b1" 2>/dev/null && pwd -P)" || b2="$b1"
  fi
  AIF_G_N1="$n1" AIF_G_N2="$n2" AIF_G_B1="$b1" AIF_G_B2="$b2" awk -v bf="$3" '
    function repl(s, from, to,   out, i) {
      if (from == "") return s
      out = ""
      while ((i = index(s, from)) > 0) {
        out = out substr(s, 1, i - 1) to
        s = substr(s, i + length(from))
      }
      return out s
    }
    # The longer spelling first: /private/var/x holds /var/x.
    function roots(s, a, b,   t) {
      if (length(b) > length(a)) { t = a; a = b; b = t }
      return repl(repl(s, a, "<root>"), b, "<root>")
    }
    function clean(s) { sub(/\r$/, "", s); gsub(/\033\[[0-9;]*m/, "", s); return s }
    function norm(s) {
      sub(/^[ \t]*[0-9]+:[0-9]+/, "#:#", s)
      gsub(/\([0-9]+,[0-9]+\)/, "(#,#)", s)
      gsub(/:[0-9]+/, ":#", s)
      gsub(/[0-9]+(\.[0-9]+)? ?(ms|seconds|secs|sec|s)([^A-Za-z0-9]|$)/, "#", s)
      gsub(/[0-9]+ (errors|error|problems|problem|warnings|warning|files|file)/, "# n", s)
      return s
    }
    BEGIN {
      while ((getline line < bf) > 0) {
        line = clean(line)
        if (line !~ /[^ \t]/) continue
        seen[norm(roots(line, ENVIRON["AIF_G_B1"], ENVIRON["AIF_G_B2"]))]++
      }
    }
    { line = clean($0) }
    line !~ /[^ \t]/ { next }
    {
      k = norm(roots(line, ENVIRON["AIF_G_N1"], ENVIRON["AIF_G_N2"]))
      if (seen[k] > 0) seen[k]--
      else print line
    }
  ' "$1"
}

# aif_g_located <file> <paths-file> [<except-ere>] — the lines of <file> that
# name one of the paths in <paths-file>, and match not <except-ere>, each with
# the indented lines that continue it.
#
# "Name" is a substring test, so a tool that prints paths relative to the root
# and one that prints them absolute are both caught. Continuation lines are how
# a compiler says the rest of one problem — tsc's "Source has 0 element(s) but
# target requires 1." is the third line of its diagnostic and names no file.
aif_g_located() {
  AIF_G_EXCEPT="${3:-}" awk -v pf="$2" '
    BEGIN {
      while ((getline p < pf) > 0) if (p != "") paths[++np] = p
      except = ENVIRON["AIF_G_EXCEPT"]
    }
    { sub(/\r$/, ""); gsub(/\033\[[0-9;]*m/, ""); line = $0; named = 0
      for (i = 1; i <= np; i++) if (index(line, paths[i]) > 0) { named = 1; break }
      if (named && !(except != "" && line ~ except)) { print line; ctx = 4; next }
      if (!named && ctx > 0 && line ~ /^[ \t]/) { print line; ctx--; next }
      ctx = 0 }
  ' "$1"
}

# aif_g_excerpt <file> [<lines>] — the first non-blank lines of a command's
# output, indented as the continuation of a violation (see aif_g_report).
aif_g_excerpt() {
  awk -v max="${2:-15}" '
    { sub(/\r$/, ""); gsub(/\033\[[0-9;]*m/, "") }
    /[^ \t]/ { if (++n > max) exit; print "    " substr($0, 1, 240) }
  ' "$1"
}

# aif_g_checks_run <project> <root> <phase> <record> [<tests>] [<keep>] — run
# the project's checks for one phase. Echoes the violations (empty = nothing
# required failed), and writes <record>: a JSON array of every check that ran,
# so a failure is attributable to a named check rather than to "the station".
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
#
# A violation carries the check's OWN words, as indented continuation lines:
# the first lines of its output. It used to carry `tail -1`, and for tsc the
# last line of a failure is "Source has 0 element(s) but target requires 1." —
# no file, no line. The station it was sent back to could not tell where the
# error was, and spent three attempts not finding it (docs/DEFECTS.md 6.2).
#
# <tests> — at "red", the ticket's declared test files, one per line. A check
# the project bound to red that carries `legitimate_at_red` (a list of EREs) is
# judged against them rather than by its exit code alone. At red no
# implementation exists, so a compiler over the whole tree fails CORRECTLY on
# every import of a module the plan has not created yet; what the tests can be
# rejected for is a line that names one of THEIR files and is not one of those
# expected failures — a type error in a mock, say, which jest runs happily
# because babel strips types. A check without the field keeps the old rule:
# any failure is a violation. Result "expected" in the record says a failure
# was read that way and let through; "unlocated" says it failed and named none
# of the test files, which is not the tests' to fix (verify-red stops on it).
#
# <keep> — a directory: the whole output of every required check that failed
# is kept there as <n>.out, with "<n><TAB><name>" in failed.tsv, so green can
# run the same check again without the implementation and compare.
#
# <base> <dir> — the tree before this ticket (aif_g_ticket_base), and where the
# gate keeps its one copy of it. A required check that failed is run there too
# (aif_g_base_check) before it is judged, and judged on what is NEW with this
# ticket (aif_g_new_lines): failing there, and nothing new here, it is the
# repository's — result "at_base", let through and named by the gate, never a
# station's to fix: a type error landed on main used to reject every plan at
# contract, stop every tests station at red and reject every implementation at
# green, behind files no station may touch (docs/DEFECTS.md 13.9). Lines new
# with this ticket are judged as ever, and alone — the excerpt, and at red the
# located and legitimate_at_red reading, are of those lines; the complaint
# says how many fail the same way before it. A copy that cannot be made exits
# 3 (aif_g_error): the caller's `$(…)` returns it, and the caller stops.
aif_g_checks_run() {
  local project="$1" root="$2" phase="$3" record="$4" tests="${5:-}" keep="${6:-}"
  local base="${7:-}" dir="${8:-}"
  local name cmd required rc out n=0 rows="" viol="" tab result note legit bad tf=""
  local brow brc b_rc b_out all newn same_say
  tab="$(printf '\t')"

  : >"$record"

  # No checks for this phase is the common case and must cost nothing.
  if [ "$(jq --arg p "$phase" \
    '[.checks[]? | select((.phase // []) | index($p))] | length' "$project" 2>/dev/null)" \
    = "0" ]; then
    printf '[]' >"$record"
    return 0
  fi

  if [ "$phase" = "red" ] && [ -n "$tests" ]; then
    tf="$(mktemp "${TMPDIR:-/tmp}/aif-tests-XXXXXX")"
    printf '%s\n' "$tests" | grep -v '^[[:space:]]*$' >"$tf" || true
  fi

  while IFS="$tab" read -r name required; do
    [ -n "$name" ] || continue
    n=$((n + 1))
    # The command is read raw, by name, rather than through the @tsv below:
    # @tsv doubles every backslash, so a command with one in it ran as a
    # different command — and green now runs the same check a second time,
    # from project.json, to compare the two.
    cmd="$(jq -r --arg n "$name" '[ .checks[]? | select(.name == $n) | .command ] | .[0] // empty' "$project")"
    out="$(mktemp "${TMPDIR:-/tmp}/aif-check-XXXXXX")"
    rc=0
    # stdin from /dev/null: this loop reads the check list from its own stdin,
    # and a command that reads stdin would swallow the checks after it.
    (cd "$root" && eval "$cmd") </dev/null >"$out" 2>&1 || rc=$?
    result=pass
    note="$(tail -3 "$out" | tr '\n\t' '  ')"
    same_say=""
    if [ "$rc" -ne 0 ] && [ "$required" = "true" ] && [ -n "$base" ] && [ -n "$dir" ]; then
      brc=0
      brow="$(aif_g_base_check "$project" "$root" "$base" "$name" "$dir")" || brc=$?
      [ "$brc" -ne 2 ] ||
        aif_g_error "could not copy the tree to run check \"$name\" before this ticket (at $(printf '%s' "$base" | cut -c1-10)): $brow"
      if [ "$brc" -eq 0 ]; then
        b_rc="${brow%%"$tab"*}"
        b_out="${brow#*"$tab"}"
        if [ "$b_rc" != "0" ]; then
          aif_g_new_lines "$out" "$root" "$b_out" >"$out.new"
          if [ ! -s "$out.new" ]; then
            result=at_base
            note="exit $rc, and exit $b_rc before this ticket (at $(printf '%s' "$base" | cut -c1-10)) with nothing new — let through"
          else
            all="$(grep -c '[^[:space:]]' "$out" || true)"
            newn="$(grep -c '[^[:space:]]' "$out.new" || true)"
            [ $((all - newn)) -le 0 ] ||
              same_say="  $((all - newn)) line(s) of it fail the same way before this ticket (at $(printf '%s' "$base" | cut -c1-10)), and are not counted here"
            cp "$out.new" "$out"
          fi
        fi
        rm -f "$out.new"
      fi
    fi
    if [ "$rc" -ne 0 ] && [ "$result" != "at_base" ]; then
      result=fail
      # Raw too, for the same reason: `expect\(` through @tsv would reach awk
      # as a different regex.
      legit=""
      if [ -n "$tf" ]; then
        legit="$(jq -r --arg n "$name" \
          '[ .checks[]? | select(.name == $n) | (.legitimate_at_red // [])[] ] | join("|")' "$project")"
      fi
      if [ -n "$legit" ]; then
        bad="$(aif_g_located "$out" "$tf" "$legit")"
        if [ -z "$(aif_g_located "$out" "$tf")" ]; then
          # It failed, and not in the tests: the repository fails this check
          # without them, or the check prints paths from somewhere other than
          # the project root. Either way nothing here could be read as the
          # tests' — and read as "expected", it would be a check that never
          # fails. "unlocated" in the record; the caller stops on it.
          result=unlocated
          note="exit $rc, and no line of it names this ticket's test files"
          [ "$required" != "true" ] || viol="$viol
check \"$name\" failed at red (exit $rc), and none of its output names this ticket's test files — its output begins:
$(aif_g_excerpt "$out")
$same_say"
        elif [ -z "$bad" ]; then
          result=expected
          note="exit $rc; every line naming this ticket's test files is one legitimate_at_red expects"
        elif [ "$required" = "true" ]; then
          viol="$viol
check \"$name\" fails in this ticket's test files beyond what legitimate_at_red expects (exit $rc):
$(printf '%s\n' "$bad" | sed -n '1,15p' | cut -c1-240 | sed 's/^/    /')
$same_say"
        fi
      elif [ "$required" = "true" ]; then
        viol="$viol
check \"$name\" failed (exit $rc) — its output begins:
$(aif_g_excerpt "$out")
$same_say"
        if [ -n "$keep" ] && [ -d "$keep" ]; then
          cp "$out" "$keep/$n.out" 2>/dev/null || true
          printf '%s\t%s\n' "$n" "$name" >>"$keep/failed.tsv"
        fi
      fi
      if [ "$result" = "fail" ] && [ "$required" != "true" ]; then
        printf 'warn: optional check "%s" failed (exit %s) — recorded, not blocking\n' \
          "$name" "$rc" >&2
      fi
    fi
    rows="$rows$name$tab$rc$tab$required$tab$result$tab$note
"
    rm -f "${out:?}"
  done <<EOF
$(jq -r --arg p "$phase" '.checks[]?
  | select((.phase // []) | index($p))
  | [ .name, (if .required == false then "false" else "true" end) ]
  | @tsv' "$project")
EOF
  [ -z "$tf" ] || rm -f "${tf:?}"

  jq -n --arg phase "$phase" --rawfile raw <(printf '%s' "$rows") '
    $raw | split("\n") | map(select(length > 0) | split("\t"))
    | map({ phase: $phase, name: .[0], exit: (.[1] | tonumber),
            required: (.[2] == "true"), result: .[3],
            tail: (.[4] // "") })' >"$record"

  printf '%s\n' "$viol" | sed '/^[[:space:]]*$/d'
}

# aif_g_report <violations> <label> — reject with a numbered list, or pass.
#
# Every violation is printed, never just the first. A gate that reports one
# problem per run turns a fix into a guessing game and burns a station attempt
# per line.
#
# A line that starts with whitespace continues the violation above it — a
# command's own output, quoted — and is printed under it rather than counted
# as a problem of its own.
aif_g_report() {
  local violations="$1" label="$2"
  local count

  if [ -z "$violations" ]; then
    return 0
  fi

  count="$(printf '%s\n' "$violations" | grep -c '^[^[:space:]]')"
  printf 'REJECT %s: %s problem(s)\n' "$label" "$count" >&2
  # Drop blank lines: an accumulator that prepends "\nMSG" leaves a leading
  # empty that would otherwise print as a bare bullet.
  printf '%s\n' "$violations" |
    sed '/^[[:space:]]*$/d; /^[[:space:]]/s/^/    /; /^[^[:space:]]/s/^/  - /' >&2
  exit "$AIF_G_REJECT"
}
