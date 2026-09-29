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

# Paths no implementation may touch, whatever the plan says: the pipeline's own
# machinery, config and CI. Anchored so they match from the repo root only.
#
# ONE list, TWO gates, and that is the point of it living here. The plan gate
# rejects a manifest path matching it at plan time, where the fix costs a
# re-plan; scope holds the same line against the diff after the code exists, as
# the backstop. When the two lists were one gate's private constant they
# disagreed: a plan named yarn.lock in files.change, both plan gates accepted
# it, and scope would then have rejected the implementation for doing exactly
# what the approved plan permitted.
# shellcheck disable=SC2034
AIF_G_DENYLIST='^\.aif/|^tasks/|^\.claude/|^\.github/|^\.gitlab-ci|^project\.json$|^\.aif/project\.json$|^\.gitignore$'

# Dependency manifests, and the lockfiles that pin what they ask for.
#
# The lockfiles used to sit on the denylist, "until a sanctioned route for
# dependency changes is answered". The manifests never did — and that half-open
# door is how a dependency got into a ticket's worktree around its lock: the
# plan named package.json, the lockfile could not be named, and a station
# installed the package without it. npm then re-resolved packages nobody had
# asked to move, into an incompatible pair, and twelve pre-existing tests went
# red where no diff to the manifest could reach them (docs/DEFECTS-6.md #3).
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
  # sends the human to the wrong place (docs/DEFECTS-3.md #10).
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
# tests for not depending on it (docs/DEFECTS-3.md #8). So the worker writes
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

# aif_g_scratch_at <root> <base> — a throwaway copy of the working tree as it
# stood at <base>, echoed. Every path the tree changed since that commit (see
# aif_g_changed_since) is put back to <base>'s content, or removed where <base>
# did not have it. What git ignores — node_modules, a virtualenv, a build cache
# — is copied as it stands, because that is what a suite runs against.
#
# The caller removes it. .aif/worktrees/ is left behind: those are the worker's
# other checkouts, complete trees with their own installed dependencies, and
# nothing a suite here reads.
#
# Git is only ever asked READ-ONLY questions of the real repository here, and
# is never run inside the copy. A copy of a linked worktree carries its .git
# FILE, which points at the real worktree's gitdir: `git checkout <base> -- f`
# run in the copy restores the copy's file and stages <base>'s blob in the REAL
# worktree's index. green's revert-recheck did exactly that for as long as it
# existed (docs/DEFECTS-6.md #4).
aif_g_scratch_at() {
  local root="$1" base="$2" scratch p q
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/aif-scratch-XXXXXX")" || return 1
  # Resolved once, here. macOS's TMPDIR ends in "/", so mktemp hands back
  # ".../T//aif-scratch-…" — and a suite run after `cd` into it prints
  # ".../T/aif-scratch-…" (or /private/var/…), a spelling no comparison of the
  # two runs' output then recognises as the copy.
  scratch="$(cd "$scratch" && pwd -P)" || return 1
  for p in "$root"/* "$root"/.[!.]* "$root"/..?*; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    if [ "$p" = "$root/.aif" ] && [ -d "$p/worktrees" ]; then
      mkdir -p "$scratch/.aif"
      for q in "$p"/* "$p"/.[!.]* "$p"/..?*; do
        [ -e "$q" ] || [ -L "$q" ] || continue
        [ "$q" = "$p/worktrees" ] || cp -R "$q" "$scratch/.aif/" 2>/dev/null || true
      done
    else
      cp -R "$p" "$scratch/" 2>/dev/null || true
    fi
  done
  if [ -n "$base" ]; then
    aif_g_changed_since "$root" "$base" | while IFS= read -r p; do
      [ -n "$p" ] || continue
      if git -C "$root" cat-file -e "$base:$p" 2>/dev/null; then
        mkdir -p "$scratch/$(dirname "$p")"
        git -C "$root" show "$base:$p" >"$scratch/$p" 2>/dev/null || true
      else
        rm -f "${scratch:?}/${p:?}"
      fi
    done
  fi
  printf '%s' "$scratch"
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
# error was, and spent three attempts not finding it (docs/DEFECTS-6.md #2).
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
aif_g_checks_run() {
  local project="$1" root="$2" phase="$3" record="$4" tests="${5:-}" keep="${6:-}"
  local name cmd required rc out n=0 rows="" viol="" tab result note legit bad tf=""
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
    if [ "$rc" -ne 0 ]; then
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
$(aif_g_excerpt "$out")"
        elif [ -z "$bad" ]; then
          result=expected
          note="exit $rc; every line naming this ticket's test files is one legitimate_at_red expects"
        elif [ "$required" = "true" ]; then
          viol="$viol
check \"$name\" fails in this ticket's test files beyond what legitimate_at_red expects (exit $rc):
$(printf '%s\n' "$bad" | sed -n '1,15p' | cut -c1-240 | sed 's/^/    /')"
        fi
      elif [ "$required" = "true" ]; then
        viol="$viol
check \"$name\" failed (exit $rc) — its output begins:
$(aif_g_excerpt "$out")"
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
