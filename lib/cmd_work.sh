#!/usr/bin/env bash
#
# `aif work [<ticket>]` — the worker: one ticket, one worktree, one budget, no
# questions. Sourced by bin/aif; not meant to be executed directly.
#
# This is the machine half of the foundry (docs/REBUILD-3.md §3). The human
# half — the product conversation, the analyst, the board — happens in ordinary
# sessions, in the human's own time. What crosses the boundary is a ticket that
# is READY, and what comes back is a branch and a report. Nothing in between
# asks anybody anything: a question the worker cannot answer from the ticket
# and the repository is, by definition, the failure mode, and it is reported as
# one rather than waited on.
#
# Shape:
#
#   preflight   profile, runner, board, toolchain — before the first token
#               (the old `aif run` learned the last one at ~$6.61 on a live
#               ticket, at the LAST gate)
#   board       the card moves to In Progress before anything is spent
#   worktree    git worktree add .aif/worktrees/<ID> -b aif/<ID>. A disposable
#               checkout of its own: nothing a station writes reaches the
#               developer's tree until they merge the branch
#   intake      the ticket's bytes are hashed, recorded and committed. From
#               here the inputs are FROZEN for the run's lifetime — a ticket
#               edited on the board mid-run changes nothing here, and the
#               report says which bytes were built. That one rule is what let
#               the backward-lapsing hash cascade be deleted (lib/run.sh)
#   loop        the run record says which stage is next; the worker dispatches
#               that station as `claude -p` with the station's own prompt,
#               `aif _record` stamps the binding (never the model), `aif _gate`
#               judges and records the verdict, `aif _commit` seals it and the
#               stage advances. A rejection is a RETRY with the gate's
#               complaint in the prompt, up to the station's attempts cap
#               (max_attempts in its aif:meta, else limits.attempts_max) —
#               never a conversation
#   report      tasks/<ID>/report.md and the station transcripts, committed to
#               the branch and posted to the card. The human reviews that next
#               to the diff, which is the one place they have enough context
#
# Exit: 0 built · 1 stopped, needs a human (the report says why) · 3 the
# environment cannot run a ticket at all (nothing was spent).

# AIF_WORK_WORKTREES lives in lib/paths.sh: `aif doctor` needs it too, to tell
# a project whose test runner is collecting these checkouts beside the real tree.

_aif_work_usage() {
  cat <<EOF
usage: aif work [<ticket>] [options]

  Build one ticket, headless, on its own branch. Never asks a question: a
  ticket the worker cannot build from what it was given comes back with a
  report saying what was missing.

    aif work                    the ticket at the top of the board's Ready column
    aif work OPES-52            this one, in .aif/worktrees/OPES-52 on aif/OPES-52
    aif work OPES-52 --clean    remove that worktree (the branch stays)
    aif work --loop             every card in Ready, in the board's order, one run each

  Every transition goes through the board (aif board): the card moves to In
  Progress when the run starts, and to Review — or Needs Human, with the
  report as a comment — when it ends.

  --profile P        which (set, runner, model) profile; default: the project's
  --budget USD       stop past this spend. OFF unless asked for: set it here
                     or as limits.run_budget_usd. Each station is priced from
                     its tokens where .aif/prices.json knows the model, else as
                     the runner reported it — under subscription auth that is
                     \$0, so an unpriced model contributes nothing to the total
  --no-budget        no dollar ceiling, whatever limits.run_budget_usd says
  --max-minutes N    stop past this wall clock (default limits.run_max_minutes, 120)
  --no-worktree      run in the current checkout instead of a worktree. Every
                     station then runs with bypassPermissions HERE, so the
                     checkout must already be disposable: set CI=1 (a CI job
                     has it) or AIF_DISPOSABLE=1 to say so. Refused otherwise
  --clean            remove the ticket's worktree and stop
  --loop             after each run take the next card in Ready, until Ready is
                     empty. Stops early when a run cannot start, or after two
                     runs in a row that did not build — two cards in Needs Human
                     usually mean the problem is not the cards
  --max-tickets N    with --loop: stop after N tickets

Two caps always apply — the wall clock and limits.run_dispatches_max (16
station runs). The dollar ceiling is the third and is opt-in: under
subscription auth the runner reports \$0 for every station and
.aif/prices.json ships empty, so a ceiling nobody configured could not fire.
Price your model there before relying on one.

A fresh worktree holds tracked files only. "prepare" in .aif/project.json
(npm ci, bundle install) runs once after it is cut, and the suite is then
probed THERE before anything is spent — a checkout that cannot run the suite
is refused, not built against.

The worker is the whole dev pipeline. There is no command per stage, and there
is no question at any stage; see docs/REBUILD-3.md.
EOF
}

# _aif_work_say <label> <text> — one dim status line on stderr.
_aif_work_say() {
  printf '%s%-9s%s %s\n' "$AIF_C_DIM" "$1" "$AIF_C_RESET" "$2" >&2
}

# _aif_work_abandon — the card stops claiming that work is happening.
#
# Armed for EXIT, INT and TERM the moment the card moves to In Progress, and it
# has to cover all three. Ctrl-C and a supervisor's TERM are the obvious two;
# the common one is neither — it is any `aif_die` or `set -e` failure between
# the move and the report, which used to leave the card In Progress with
# nobody working on it. That is the same defect as a meter that quietly did
# not fire, and for one release the handler meant to prevent it was disarmed
# by the first ledger write of every run (docs/DEFECTS-3.md #1-#3).
#
# Idempotent, and silent once the run has settled the card itself. Where it
# does act it exits 1, because a run nobody finished IS "stopped, needs a
# human" — which is what 1 means here.
_aif_work_abandon() {
  [ "${AIF_WORK_SETTLED:-0}" = "0" ] || return 0
  AIF_WORK_SETTLED=1
  [ -n "${AIF_WORK_CARD:-}" ] || return 0
  aif_board_move "$AIF_WORK_ROOT" "$AIF_WORK_CARD" needs_human >/dev/null 2>&1 || true
  printf '\n%s did not finish — moved to needs_human; the branch keeps what was accepted\n' \
    "$AIF_WORK_CARD" >&2
  exit 1
}

# _aif_work_preflight <root> <profile> — everything that can refuse a run
# before it costs anything: the project's config, the stations, the runner and
# its credential, the board as configured, and the test toolchain.
_aif_work_preflight() {
  local root="$1" profile="$2"
  local project problems

  project="$(aif_project_config "$root")"
  [ -f "$project" ] || aif_die "no .aif/project.json — run 'aif project init'"
  problems="$(aif_project_validate "$project")"
  if [ -n "$problems" ]; then
    aif_err "project.json has problems — the gates read it, so fix these first:"
    printf '%s\n' "$problems" | sed 's/^/  - /' >&2
    exit 3
  fi

  [ -f "$root/.claude/agents/aif-implement.md" ] ||
    aif_die "the stations are not installed — run 'aif init'"

  # The project's guide to its own tests, which the plan and tests stations
  # are handed as part of their instructions (docs/REBUILD-4.md §6). Absent,
  # the stations would be told to read a file that is not there; stale — a
  # path it cites gone — they would be sent to one. Both are the environment,
  # answered before a token is spent, the way a missing project.json is.
  local guide_missing
  if [ ! -f "$(aif_guide_path "$root")" ]; then
    aif_err "no $AIF_GUIDE_FILE — the plan and tests stations read it. Write it from the repository first: aif project guide"
    exit 3
  fi
  guide_missing="$(aif_guide_missing_paths "$root")"
  if [ -n "$guide_missing" ]; then
    aif_err "$AIF_GUIDE_FILE names paths that no longer exist — the stations would be sent to them:"
    printf '%s\n' "$guide_missing" | sed 's/^/  - /' >&2
    aif_err "aif project guide brings its generated block up to date; what you wrote by hand is yours to fix. Nothing was spent."
    exit 3
  fi

  # A project.json behind the template it was made from: the gates read the
  # file as it is, so this is a warning and not a refusal — but said on every
  # run, because an upgraded project kept failure classes the gate no longer
  # means and nothing told it (docs/DEFECTS-8.md #1).
  local drift_n
  drift_n="$(aif_project_drift "$project" | grep -c . || true)"
  if [ "${drift_n:-0}" -gt 0 ]; then
    aif_warn "project.json is behind its template — $drift_n thing(s) moved since it was written; the gates read the file as it is. aif project check lists them; aif project upgrade brings them forward"
  fi

  aif_profile_load "$profile"
  # shellcheck source=lib/runner_claude.sh
  . "$AIF_ROOT/lib/runner_claude.sh"
  if [ -z "${AIF_WORK_STATION_CMD:-}" ]; then
    "aif_runner_${AIF_PROFILE_RUNNER}_available" ||
      aif_die "runner '$AIF_PROFILE_RUNNER' is not installed"
    if [ -n "$AIF_PROFILE_SECRET_VAR" ] && [ -z "$(aif_profile_secret)" ]; then
      aif_die "$AIF_PROFILE_SECRET_VAR is not set — export it to use profile '$profile'"
    fi
  fi

  # The board, before the first token. A token that expired since setup stops
  # the run here with one line, not as a card that quietly never moved after
  # the work was done.
  if ! aif_board_check "$root" >/dev/null 2>&1; then
    aif_board_check "$root" >&2 || true
    aif_err "the board is not reachable as configured — fix that first (aif board check)"
    exit 3
  fi

  # In the developer's checkout: the reporter, the report path, and whether
  # the runner is collecting .aif/worktrees/ beside the real tree — that last
  # one is only visible from here. Whether the suite can run where the
  # STATIONS run is a different question, asked of the worktree once it is
  # cut (_aif_work_ready_worktree).
  # shellcheck source=lib/doctor.sh
  . "$AIF_ROOT/lib/doctor.sh"
  if ! aif_doctor_probe "$root" >/dev/null 2>&1; then
    aif_doctor_probe "$root" >&2 || true
    aif_err "the test toolchain cannot produce a verdict — every gate reads that report."
    exit 3
  fi

  aif_profile_export_env
  if [ "${AIF_PROFILE_ISOLATE_CONFIG:-0}" = "1" ]; then
    CLAUDE_CONFIG_DIR="$(aif_runner_config_dir "$profile")"
    export CLAUDE_CONFIG_DIR
    mkdir -p "$CLAUDE_CONFIG_DIR"
  fi
}

# _aif_work_worktree <root> <ticket> — the checkout this run happens in, echoed.
#
# Created on first use, reused on a resume. The branch is aif/<ticket>; a branch
# that already exists (an earlier run, a review in progress) is checked out
# rather than recreated, so a second `aif work` on the same ticket continues
# where the first stopped — the run record says where that is.
_aif_work_worktree() {
  local root="$1" ticket="$2"
  local wt branch
  wt="$root/$AIF_WORK_WORKTREES/$ticket"
  branch="aif/$ticket"

  if [ -e "$wt/.git" ]; then
    printf '%s' "$wt"
    return 0
  fi

  # shellcheck source=lib/merge.sh
  . "$AIF_ROOT/lib/merge.sh"
  aif_gitignore_ensure "$root" "$AIF_WORK_WORKTREES/" "worker checkouts — one per ticket, disposable"

  mkdir -p "$(dirname "$wt")"
  if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$root" worktree add -q "$wt" "$branch" >/dev/null 2>&1 ||
      aif_die "could not check out $branch into $wt"
  else
    git -C "$root" worktree add -q -b "$branch" "$wt" >/dev/null 2>&1 ||
      aif_die "could not create worktree $wt on $branch"
  fi
  printf '%s' "$wt"
}

# _aif_work_ready_worktree <root> <wt> <ticket> — make the checkout the
# stations will run in able to run the suite, and prove it, before anything
# is spent or any card moves.
#
# `git worktree add` checks out tracked files and nothing else. node_modules
# is gitignored, so a fresh worktree has none, and jest dies validating its
# config before it runs a single test — no report, exit 1. For three runs of
# one ticket that was admitted as coarse RED, the freeze recorded an empty
# `covering`, and green passed a build whose tests nobody had seen fail
# (docs/DEFECTS-4.md #11). The preflight probe could not have seen it: it
# runs in the developer's checkout, where node_modules exists.
#
# Two things, in order:
#   prepare — project.json's "prepare" (npm ci, bundle install), run once per
#             worktree. A marker under .aif/tmp/ — gitignored, per checkout —
#             says it happened, so a resume does not repeat it and a prepare
#             that died halfway is tried again.
#   probe   — the same probe `aif doctor --probe` runs, but HERE. Its whole
#             value is running where the stations run.
# rc 0 usable · 3 the checkout cannot run the suite, and the run must not
# start — nothing was spent, the card has not moved.
_aif_work_ready_worktree() {
  local root="$1" wt="$2" ticket="$3"
  local prepare marker log rc=0

  # From the DEVELOPER'S config, not the worktree's. The branch was cut from
  # whatever HEAD was on the first run, and the run that gets refused here is
  # exactly the one after which someone adds "prepare" — to a file the branch
  # does not have yet. Provisioning is the developer's live instruction; what
  # the suite IS still comes from the worktree, through the probe below.
  prepare="$(jq -r '.prepare // empty' "$(aif_project_config "$root")" 2>/dev/null)"
  marker="$wt/.aif/tmp/prepared"
  if [ -n "$prepare" ] && [ ! -f "$marker" ]; then
    _aif_work_say "prepare" "$prepare"
    mkdir -p "$wt/.aif/tmp"
    log="$wt/.aif/tmp/prepare.log"
    (cd "$wt" && eval "$prepare") >"$log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      aif_err "prepare failed (exit $rc) in ${wt#"$root"/} — the run cannot start, nothing was spent:"
      tail -8 "$log" | sed 's/^/    /' >&2
      aif_err "the command is \"prepare\" in .aif/project.json; the full log is ${log#"$root"/}"
      return 3
    fi
    : >"$marker"
  fi

  # shellcheck source=lib/doctor.sh
  . "$AIF_ROOT/lib/doctor.sh"
  if ! aif_doctor_probe "$wt" >/dev/null 2>&1; then
    aif_doctor_probe "$wt" >&2 || true
    aif_err "the suite cannot run in ${wt#"$root"/}, where the stations run — nothing was spent."
    if [ -z "$prepare" ]; then
      aif_err "A fresh worktree holds tracked files only. If the runner needs installed"
      aif_err "dependencies, set \"prepare\" in .aif/project.json (e.g. \"npm ci\") and the"
      aif_err "worker runs it once after cutting the worktree."
    fi
    return 3
  fi
  return 0
}

# _aif_work_reprepare <root> <wt> <work> — install the dependencies again when
# the station just dispatched changed a dependency manifest or its lockfile.
#
# "prepare" runs once, when the worktree is cut, and after that node_modules was
# whatever the stations left. On a live ticket that was a package installed
# around its lockfile: npm re-resolved packages nobody had asked to move, into
# an incompatible pair, and green then blamed the implementation three times
# for twelve pre-existing tests that no edit to its files could reach
# (docs/DEFECTS-6.md #3). A lockfile is the promise of what an install builds;
# the gates should judge THAT, so the install is made again from it, the way
# CI and the next developer will make it. `npm ci` refuses a manifest the lock
# does not match — which turns "installed around the lock" from a silent drift
# into a complaint the station can act on.
#
# Read from the developer's config, like the first prepare. Nothing to do
# without a "prepare", or when the station changed neither kind of file.
# rc 0 nothing to do, or installed · 1 prepare failed; AIF_WORK_REPREPARE holds
# the complaint for the station.
_aif_work_reprepare() {
  local root="$1" wt="$2" work="$3" prepare base files log rc=0
  AIF_WORK_REPREPARE=""
  prepare="$(jq -r '.prepare // empty' "$(aif_project_config "$root")" 2>/dev/null)"
  [ -n "$prepare" ] || return 0
  base="$(aif_run_get "$work" '.dispatch_base')" || base=""
  [ -n "$base" ] || return 0
  files="$({
    git -C "$wt" -c core.quotePath=false diff --name-only "$base" 2>/dev/null
    git -C "$wt" -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null
  } | grep -E "$AIF_DEP_MANIFESTS|$AIF_DEP_LOCKFILES" | sort -u)" || files=""
  [ -n "$files" ] || return 0

  _aif_work_say "prepare" "$(printf '%s' "$files" | paste -sd ' ' -) changed — $prepare"
  mkdir -p "$wt/.aif/tmp"
  log="$wt/.aif/tmp/prepare.log"
  (cd "$wt" && eval "$prepare") </dev/null >"$log" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || return 0

  AIF_WORK_REPREPARE="The station changed $(printf '%s' "$files" | paste -sd ' ' - | sed 's/ /, /g'), and \"prepare\" ($prepare) cannot install what it left — exit $rc:
$(grep -v '^[[:space:]]*$' "$log" | sed 's/\x1b\[[0-9;]*m//g' | tail -12 | cut -c1-240 | sed 's/^/    /')
A dependency manifest and its lockfile change together: change dependencies through the package manager, so the lockfile records what the manifest asks for (npm install <package>), never around it (--no-save, --no-package-lock, a hand edit). The worker installs from the lockfile after every station that touches either. If the plan does not name the lockfile, stop and say so — that is the plan's defect."
  return 1
}

# _aif_work_intake <root> <wt> <ticket> — carry the ticket in, judge it ready,
# and open (or resume) the run record.
#
# This is the seam the whole design rests on. After it, the ticket's bytes do
# not move for the life of the run: the plan is made for them, the tests freeze
# against the plan, and the report says which bytes were built. A card edited
# while the worker runs changes the NEXT run, not this one.
#
# rc 0 ready · 1 there is no ticket to build · 2 the ticket is not ready, and
# AIF_WORK_NOT_READY holds the gate's own lines.
_aif_work_intake() {
  local root="$1" wt="$2" ticket="$3"
  local work src base rc=0 out

  work="$(aif_task_dir "$wt" "$ticket")"
  src="$(aif_task_dir "$root" "$ticket")"

  # The board is canonical for the ticket's text until this moment: on a
  # trello board the card's description is pulled into THIS checkout and
  # becomes the bytes the run freezes. The local board holds no text — the
  # ticket is already in tasks/, and the copy below carries it in.
  if [ "$(aif_board_kind "$wt")" = "trello" ]; then
    (aif_board_pull "$wt" "$ticket" >/dev/null) || {
      aif_err "could not pull $ticket from the board — nothing was built."
      return 1
    }
  elif [ ! -f "$work/ticket.md" ] && [ -f "$src/ticket.md" ] && [ "$src" != "$work" ]; then
    mkdir -p "$work"
    cp -R "$src/." "$work/"
  fi

  [ -f "$work/ticket.md" ] || {
    aif_err "no ticket: $AIF_TASKS_DIR/$ticket/ticket.md does not exist."
    aif_err "The worker builds tickets; it does not write them. Write one with /aif-ba, then run this again."
    return 1
  }
  [ -f "$(aif_ledger_path "$work")" ] || aif_ledger_init "$work" "$ticket"

  # The Definition of Ready — the same gate the analyst ran, against the bytes
  # this run is about to freeze. Recorded either way: the ledger says what was
  # judged buildable, not merely that a build was attempted.
  out="$(aif_gate_run "$wt" ready "$work")" || rc=$?
  [ "$rc" -ne 127 ] || aif_die "the ready gate is not installed in this project — run 'aif init'"
  aif_ledger_gate "$work" ready "$([ "$rc" -eq 0 ] && printf pass || printf fail)" \
    ticket.md "$(aif_sha256 "$work/ticket.md")" "$(aif_sha256 "$(aif_gate_path "$wt" ready)")" \
    "$(printf '%s' "$out" | head -1)"
  if [ "$rc" -ne 0 ]; then
    # Every line of the gate's output is a question for the analyst's
    # conversation. The worker reports them verbatim and guesses at none.
    printf '%s\n' "$out" >&2
    AIF_WORK_NOT_READY="$out"
    return 2
  fi

  base="$(git -C "$wt" rev-parse HEAD 2>/dev/null || printf 'none')"
  if [ -f "$(aif_run_path "$work")" ] && aif_run_resumable "$work"; then
    # The ticket has not moved since the last run stopped. Keep the stage; give
    # it a fresh attempt count and a fresh budget, because this is a new
    # invocation and the caps are per-invocation. NOT a fresh base: the report
    # diffs base..HEAD to say what the ticket built, and resetting it here made
    # a resumed run — one that resumes at `done` most of all — report "no code
    # changed" about a branch holding all of it (docs/DEFECTS-3.md #13). A
    # record from before the field existed gets one now, and only then.
    # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags below
    aif_run_update "$work" \
      '.attempts = {} | .dispatches = 0 | .spent_usd = 0 | .status = "running"
       | .why = null | .finished_at = null | .started_at = $at
       | .base = (.base // $base)' \
      --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg base "$base"
    _aif_work_say "resume" "$(aif_run_get "$work" '.stage') — the ticket has not changed since the last run"
  else
    if [ -f "$(aif_run_path "$work")" ]; then
      _aif_work_say "restart" "the ticket changed since the last run — the plan below it no longer answers it"
    fi
    aif_run_init "$work" "$ticket" \
      "$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '?')" \
      "$base" "${wt#"$root"/}"
  fi

  # Which ticket a metering hook's row belongs to. The worker meters from the
  # envelope directly, so this is for a session that spawns an aif-* subagent
  # of its own — fresh here, which is when it can be.
  local pointer
  pointer="$(aif_current_ticket_file "$wt")"
  mkdir -p "$(dirname "$pointer")" 2>/dev/null || true
  printf '%s\n' "$ticket" >"$pointer" 2>/dev/null || true

  git -C "$wt" add -A "$AIF_TASKS_DIR/$ticket" >/dev/null 2>&1 || true
  if ! git -C "$wt" diff --cached --quiet 2>/dev/null; then
    git -C "$wt" -c user.email="aif@local" -c user.name="aif" \
      commit -q -m "aif: intake $ticket" >/dev/null 2>&1 || true
  fi
  return 0
}

# _aif_work_attempts_max <wt> <station> <project.json> — how many times this
# station may be rejected in a row before the run stops: its own max_attempts,
# from its aif:meta, else the project-wide limits.attempts_max. The tests
# station declares four, the others fall to three (docs/REBUILD-4.md §2.4):
# it has iterated with the dry verifier already, and a fourth informed retry
# is cheaper than a human. One cap for every stage was the code for one
# release while the design said four (docs/DEFECTS-8.md #4).
_aif_work_attempts_max() {
  local n
  n="$(aif_station_meta "$1" "$2" 2>/dev/null | jq -r '.max_attempts // empty' 2>/dev/null)"
  [ -n "$n" ] || n="$(jq -r '.limits.attempts_max // 3' "$3" 2>/dev/null)"
  printf '%s' "${n:-3}"
}

# _aif_work_frontmatter <wt> <agent> <key> — a scalar from the agent's YAML
# frontmatter. Flat key: value only, which is all the set writes.
_aif_work_frontmatter() {
  awk -v key="$3" '
    NR == 1 && $0 == "---" { inblock = 1; next }
    inblock && $0 == "---" { exit }
    inblock && index($0, key ":") == 1 { sub(/^[^:]*:[ \t]*/, ""); print; exit }
  ' "$1/.claude/agents/$2.md"
}

# _aif_work_dispatch <wt> <ticket> <station> <agent> <complaint> <budget-left>
#                    <envelope-out>
#
# One station run. Writes the envelope to <envelope-out>, stages the cost row
# for `aif _gate` to fold, and returns 0 when the runner produced an envelope
# at all — the outcome of the station is read from the envelope by the caller,
# because a failed station is a recorded attempt, not an aborted one.
#
# The prompt carries no hash. It used to: the state machine computed one and
# the station was asked to copy it verbatim into its output. `aif _record`
# stamps it afterwards instead, so the model writes content and the tool writes
# provenance (lib/cmd_record.sh).
#
# AIF_WORK_STATION_CMD is the offline seam: when set, that command runs in
# place of the runner with the same arguments the runner would get, plus the
# station and ticket first. scripts/check-work.sh drives the whole worker
# through it with hand-written artifacts, the way demo.sh drives the gates.
_aif_work_dispatch() {
  local wt="$1" ticket="$2" station="$3" agent="$4" complaint="$5"
  local budget_left="$6" out="$7"
  local project sys prompt model tools max_turns err rc=0
  project="$(aif_project_config "$wt")"

  model="$(_aif_work_frontmatter "$wt" "$agent" model)"
  tools="$(_aif_work_frontmatter "$wt" "$agent" tools | tr -d ' ')"
  # The station's own cap first, from its aif:meta: the plan and tests
  # stations explore and read back, and hit the project-wide 30 in three runs
  # of five on one batch, leaving half-written files for the gate to judge.
  max_turns="$(aif_station_meta "$wt" "$station" 2>/dev/null | jq -r '.max_turns // empty' 2>/dev/null)"
  # 60, like every station's own cap: on a subscription a turn costs nothing
  # and a station cut off mid-file costs a dispatch (docs/DEFECTS-6.md); the
  # cap's remaining job is a station that loops without producing.
  [ -n "$max_turns" ] || max_turns="$(jq -r '.limits.station_max_turns // 60' "$project" 2>/dev/null)"
  [ -n "$model" ] || model="sonnet"
  [ -n "$tools" ] || tools="Read,Grep,Glob,Write,Edit"

  # The tests station's Bash is for one command, `aif _verify`, and the guard
  # hook is what holds it to that. The tool is granted only once
  # `aif doctor --probe` has watched the hook deny a command in a spawned run
  # on this machine (docs/FINDINGS.md #21) — a hook that did not fire would
  # hand the station the shell, silently. Withheld, the station still works:
  # the gate's reject loop is its only loop, slower and not weaker.
  if [ "$station" = "tests" ]; then
    case ",$tools," in
      *,Bash,*)
        if ! _aif_work_guard_probed "${AIF_WORK_ROOT:-$wt}"; then
          tools="$(printf '%s' "$tools" | tr ',' '\n' | grep -vx Bash | paste -sd, -)"
          _aif_work_say "station" "tests runs without aif _verify — the guard hook has not been seen to deny a command here (aif doctor --probe)"
        fi
        ;;
    esac
  fi

  prompt="Ticket $ticket. Your working directory is the project root. Follow your instructions exactly: read the inputs they name under $AIF_TASKS_DIR/$ticket/ and produce what they specify, nothing else. Nobody will answer a question — decide from the ticket and the repository, and record what you decided in the fields your instructions provide for it."
  if [ -n "$complaint" ]; then
    case "$complaint" in
      "REPAIR"*)
        prompt="$prompt

$complaint"
        ;;
      "REPLAN"*)
        prompt="$prompt

$complaint"
        ;;
      *)
        prompt="$prompt

The previous attempt was REJECTED. The gate's complaints, verbatim — fix exactly these, and change nothing that was not complained about:
$complaint"
        ;;
    esac
  fi

  sys="$(mktemp "${TMPDIR:-/tmp}/aif-sys-XXXXXX")"
  err="$(mktemp "${TMPDIR:-/tmp}/aif-err-XXXXXX")"
  aif_meta_body "$wt/.claude/agents/$agent.md" >"$sys"

  # The knowledge layer, after the station's own instructions: the runner
  # fragment the set ships for this project's test runner, then the project's
  # own guide (docs/REBUILD-4.md §6). Appended rather than named for the
  # station to go and read — a 60-turn station handed a file name reads it or
  # does not; handed the text, it has read it. The plan and tests stations
  # only: the implementer fills a skeleton and runs the suite with its own
  # Bash, and the seams it needs are in the plan. Stack knowledge is data the
  # pipeline supplies, not something a station is expected to carry.
  local knows="" kind frag
  case "$station" in
    plan | tests)
      kind="$(aif_project_kind "$project")"
      frag="$(aif_stack_fragment "$wt" "$kind")"
      {
        printf '\n\n---\n\n'
        if [ -n "$frag" ]; then
          cat "$frag"
          knows=" · stack $kind"
        elif [ -z "$kind" ]; then
          printf '# The stack\n\nNo runner fragment: .aif/project.json records no test.kind, and the test command names neither jest nor pytest. Work from the rules above and the project'"'"'s guide below.\n'
          _aif_work_say "station" "no runner fragment — project.json records no test.kind; $station works from its general rules"
        else
          printf '# The stack\n\nNo runner fragment ships for "%s" (%s/%s.md is not installed). Work from the rules above and the project'"'"'s guide below.\n' "$kind" "$AIF_STACKS_DIR" "$kind"
          _aif_work_say "station" "no runner fragment for '$kind' — $station works from its general rules"
        fi
        printf '\n\n---\n\n'
        if [ -f "$(aif_guide_path "$wt")" ]; then
          cat "$(aif_guide_path "$wt")"
          knows="$knows + guide"
        else
          printf '# This project'"'"'s guide\n\nThere is none (%s is missing from this checkout). Read the existing tests, fixtures and doubles yourself before writing.\n' "$AIF_GUIDE_FILE"
        fi
      } >>"$sys"
      ;;
  esac

  # The guard hook reads this: a station may write only what its station owns
  # (sets/claude/hooks/guard.sh).
  export AIF_STATION="$station"

  _aif_work_say "station" "$station · $agent · $model · ≤$max_turns turns$knows"
  # THIS aif first on the station's PATH: `aif _verify` inside the tests
  # station must reach the aif that dispatched it, not whatever Homebrew
  # installed beside it.
  local path_was="$PATH"
  export PATH="$AIF_ROOT/bin:$PATH"
  if [ -n "${AIF_WORK_STATION_CMD:-}" ]; then
    "$AIF_WORK_STATION_CMD" "$station" "$ticket" "$wt" "$sys" "$prompt" "$model" \
      "$max_turns" "$budget_left" "$tools" "$out" "$err" || rc=$?
  else
    "aif_runner_${AIF_PROFILE_RUNNER}_station" "$wt" "$sys" "$prompt" "$model" \
      "$max_turns" "$budget_left" "$tools" "$out" "$err" || rc=$?
  fi
  export PATH="$path_was"
  unset AIF_STATION
  rm -f "$sys"

  if [ ! -s "$out" ]; then
    aif_err "the runner produced no envelope for $station — $(head -1 "$err" 2>/dev/null)"
    rm -f "$err"
    return 3
  fi
  rm -f "$err"

  # Stage the cost row for `aif _gate` to fold into the ledger after the gates
  # have run. Written here and folded there for the reason every other piece of
  # this bookkeeping is: the ledger lives under tasks/, scope diffs the working
  # tree, and instrumentation must not perturb what it measures.
  local usage turns cost summary subtype model_ran result
  usage="$("aif_runner_${AIF_PROFILE_RUNNER}_result_usage" "$out")"
  turns="$(jq -r '.num_turns // 0' "$out")"
  subtype="$("aif_runner_${AIF_PROFILE_RUNNER}_result_subtype" "$out")"
  summary="$(jq -r '(.result // "") | split("\n")[0] | .[0:200]' "$out")"
  model_ran="$(jq -r '.modelUsage // {} | keys | join(",")' "$out" 2>/dev/null)"
  [ -n "$model_ran" ] || model_ran="$model"
  cost="$(_aif_meter_cost "$wt/.aif/prices.json" "$model_ran" "$usage")"
  result=error
  "aif_runner_${AIF_PROFILE_RUNNER}_result_ok" "$out" && result=ran
  _aif_meter_stage "$wt" "$ticket" "$(jq -n \
    --arg s "$station" --arg ag "$agent" --arg m "$model_ran" \
    --argjson u "$usage" --argjson t "$turns" --argjson c "$cost" \
    --arg sub "$subtype" --arg sum "$summary" --arg ok "$result" \
    '{ station: $s, agent: $ag, model: $m, mode: "headless",
       usage: $u, num_turns: $t, cost_usd: $c,
       cost_source: (if $c == null then "tokens-only" else "priced" end),
       subtype: $sub, result: $ok, summary: $sum }')"
  return 0
}

# _aif_work_envelope_cost <wt> <envelope> — what one dispatch cost, for the
# budget cap: the larger of the runner's own figure and the token-priced one.
#
# Two numbers exist for every station and they disagree. The runner's
# total_cost_usd is 0 under subscription auth (docs/FINDINGS.md #2) — the auth
# most users have. The ledger prices the same tokens from .aif/prices.json and
# that is what the report prints. The cap used to read the first, so on the
# common auth it could not fire, while the report beside it showed dollars
# (docs/DEFECTS-3.md #4). A guard against a runaway run takes the larger; a
# model prices.json does not know contributes the runner's figure alone, and
# the ledger row says "tokens-only" for it.
_aif_work_envelope_cost() {
  local wt="$1" out="$2" runner priced model usage
  runner="$(jq -r '.total_cost_usd // 0' "$out" 2>/dev/null)"
  model="$(jq -r '.modelUsage // {} | keys | join(",")' "$out" 2>/dev/null)"
  usage="$("aif_runner_${AIF_PROFILE_RUNNER}_result_usage" "$out")"
  priced="$(_aif_meter_cost "$wt/.aif/prices.json" "$model" "$usage")"
  case "$priced" in
    '' | null) priced=0 ;;
  esac
  awk -v r="${runner:-0}" -v p="$priced" 'BEGIN { printf "%.4f", (r > p) ? r : p }'
}

# _aif_work_keep_envelope <wt> <ticket> <n> <station> <envelope>
#
# The station's own account of what it did, kept rather than deleted. The bash
# orchestrator this replaces wrote each station's reasoning to a temp file and
# removed it, so a $1.27 planning step reported one line and nothing else
# (docs/REBUILD.md, defect #1).
#
# Staged under gitignored .aif/tmp/ while the run is live and moved into
# tasks/<ID>/stations/ at the end: a new file under tasks/ mid-run would show
# up in scope's diff as the implementation writing the pipeline's own record.
_aif_work_keep_envelope() {
  local wt="$1" ticket="$2" n="$3" station="$4" env="$5" dir
  dir="$wt/.aif/tmp/stations-$ticket"
  mkdir -p "$dir" 2>/dev/null || return 0
  cp "$env" "$dir/$(printf '%02d' "$n")-$station.json" 2>/dev/null || true
}

# _aif_work_guard_probed <root> — rc 0 when `aif doctor --probe` has watched
# the guard hook deny a command in a spawned run on this machine, for the
# runner version that is installed now (lib/doctor.sh writes the marker).
_aif_work_guard_probed() {
  local marker="$1/.aif/state/guard-probed" want
  [ -f "$marker" ] || return 1
  [ -z "${AIF_WORK_STATION_CMD:-}" ] || return 0
  want="$(aif_runner_version claude)"
  [ -n "$want" ] || return 1
  [ "$(cat "$marker" 2>/dev/null)" = "$want" ]
}

# _aif_work_copy_at <wt> <base> — a throwaway copy of the worktree as it stood
# at <base>, echoed: every path changed since that commit put back, every path
# added since it removed, what git ignores copied as it is. The same copy the
# gates' aif_g_scratch_at makes (which lib/ cannot source), for the same two
# reasons: a suite runs against installed dependencies, and git is never run
# inside the copy — a copy of a linked worktree carries its .git FILE, and git
# run there writes the real worktree's index (docs/FINDINGS.md #20).
_aif_work_copy_at() {
  local wt="$1" base="$2" copy p q
  copy="$(mktemp -d "${TMPDIR:-/tmp}/aif-repair-XXXXXX")" || return 1
  copy="$(cd "$copy" && pwd -P)" || return 1
  for p in "$wt"/* "$wt"/.[!.]* "$wt"/..?*; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    if [ "$p" = "$wt/.aif" ] && [ -d "$p/worktrees" ]; then
      mkdir -p "$copy/.aif"
      for q in "$p"/* "$p"/.[!.]* "$p"/..?*; do
        [ -e "$q" ] || [ -L "$q" ] || continue
        [ "$q" = "$p/worktrees" ] || cp -R "$q" "$copy/.aif/" 2>/dev/null || true
      done
    else
      cp -R "$p" "$copy/" 2>/dev/null || true
    fi
  done
  {
    git -C "$wt" -c core.quotePath=false diff --name-only "$base" 2>/dev/null
    git -C "$wt" -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null
  } | sort -u | while IFS= read -r p; do
    [ -n "$p" ] || continue
    if git -C "$wt" cat-file -e "$base:$p" 2>/dev/null; then
      mkdir -p "$copy/$(dirname "$p")"
      git -C "$wt" show "$base:$p" >"$copy/$p" 2>/dev/null || true
    else
      rm -f "${copy:?}/${p:?}"
    fi
  done
  printf '%s' "$copy"
}

# _aif_work_restore_since <wt> <base> <keep-ere> — put every path the worktree
# changed since <base> back to <base>, or remove it, except the paths matching
# <keep-ere>. In the worktree itself, through git's read-only questions and
# plain file writes — `git checkout` would be shorter and would stage.
_aif_work_restore_since() {
  local wt="$1" base="$2" keep="$3" p
  {
    git -C "$wt" -c core.quotePath=false diff --name-only "$base" 2>/dev/null
    git -C "$wt" -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null
  } | sort -u | while IFS= read -r p; do
    [ -n "$p" ] || continue
    ! printf '%s' "$p" | grep -qE "$keep" || continue
    if git -C "$wt" cat-file -e "$base:$p" 2>/dev/null; then
      mkdir -p "$wt/$(dirname "$p")"
      git -C "$wt" show "$base:$p" >"$wt/$p" 2>/dev/null || true
    else
      rm -f "${wt:?}/${p:?}"
    fi
  done
}

# _aif_work_repair <root> <wt> <ticket> <complaint> <budget-left>
#
# green attributed a failure to the frozen tests (exit 4). The tests station
# repairs them — in a COPY of the tree with the implementation reverted to the
# skeleton, so it works in the world it authored in and cannot read the code
# — and the amended files must then pass verify-red there (red against the
# skeleton) before they come back here, where green judges the implementation
# against them again without a dispatch (docs/REBUILD-4.md §2.3). Proof by
# measurement: red without the code, green with it, whichever was written
# first.
#
# Bounded per ticket by limits.repairs_max. The verify-red verdicts in the copy
# are recorded in THIS ledger; the test files, the lock and the note come back;
# the commit holds only those, so the implementation stays uncommitted and
# the next green diffs it against a baseline that already holds the new
# oracle.
#
# rc 0 repaired: run.json has regate=implement and a new dispatch_base ·
# 1 not repaired, AIF_WORK_REPAIR_WHY says why.
_aif_work_repair() {
  local root="$1" wt="$2" ticket="$3" complaint="$4" budget_left="$5" dispatched="${6:-0}"
  local work project repairs max base tests_base copy cwork agent out rc
  local attempts_max n=0 verdict reason test_files f
  AIF_WORK_REPAIR_WHY=""
  work="$(aif_task_dir "$wt" "$ticket")"
  project="$(aif_project_config "$wt")"
  max="$(jq -r '.limits.repairs_max // 2' "$project")"
  attempts_max="$(_aif_work_attempts_max "$wt" tests "$project")"
  repairs="$(aif_run_get "$work" '.repairs')"
  repairs="${repairs:-0}"
  if [ "$repairs" -ge "$max" ]; then
    AIF_WORK_REPAIR_WHY="green attributed the failure to the frozen tests again, after $repairs repair(s) (limits.repairs_max). The oracle does not converge on this ticket:
$complaint"
    return 1
  fi
  repairs=$((repairs + 1))
  # shellcheck disable=SC2016  # jq's variable, bound by --argjson
  aif_run_update "$work" '.repairs = $r' --argjson r "$repairs"

  base="$(aif_run_get "$work" '.dispatch_base')"
  tests_base="$(aif_run_get "$work" '.tests_base')"
  [ -n "$tests_base" ] || tests_base="$base"
  _aif_work_say "repair" "$repairs/$max — the tests station, in a copy without the implementation"
  copy="$(_aif_work_copy_at "$wt" "$base")" || {
    AIF_WORK_REPAIR_WHY="could not copy the tree to repair the tests in"
    return 1
  }
  cwork="$(aif_task_dir "$copy" "$ticket")"
  rm -f "$cwork/implement.note.json"
  # The baseline the gate measures against in the copy: the tree the tests
  # station started from, before this ticket's test files existed.
  # shellcheck disable=SC2016  # jq's variable, bound by --arg
  aif_run_update "$cwork" '.dispatch_base = $b' --arg b "$tests_base"

  agent="$(aif_station_agent "$copy" tests "$cwork" 2>/dev/null)"
  test_files="$(aif_meta_json "$work/plan.md" | jq -r '.files.tests[]? // empty')"
  complaint="REPAIR — the implementation of this ticket exists and is NOT in this tree: you are in a copy with it reverted to the plan's skeleton, so that the tests you amend are written against the contract and not against the code. green, judging the implementation, attributed these failures to the frozen tests rather than to the code. Read them, and either amend the tests the complaint names so they describe the criterion — red here, against the skeleton — or keep them as they are if the complaint is wrong and say so in tasks/$ticket/tests.note.json ({ \"kept\": [{ \"test\": \"<id>\", \"because\": \"…\" }] }). The gate runs again on what you leave:
$complaint"
  while :; do
    n=$((n + 1))
    if [ "$n" -gt "$attempts_max" ]; then
      AIF_WORK_REPAIR_WHY="the tests station was rejected $attempts_max time(s) in a row repairing the oracle (its attempts cap). Last complaint:
$complaint"
      break
    fi
    out="$(mktemp "${TMPDIR:-/tmp}/aif-env-XXXXXX")"
    rc=0
    _aif_work_dispatch "$copy" "$ticket" tests "$agent" "$complaint" "$budget_left" "$out" || rc=$?
    if [ "$rc" -eq 3 ]; then
      rm -f "$out"
      AIF_WORK_REPAIR_WHY="the runner could not run the tests station for the repair (no envelope) — the environment, not the ticket."
      break
    fi
    AIF_WORK_REPAIR_DISPATCHES=$((${AIF_WORK_REPAIR_DISPATCHES:-0} + 1))
    _aif_work_keep_envelope "$copy" "$ticket" "$((dispatched + AIF_WORK_REPAIR_DISPATCHES))" tests "$out"
    AIF_WORK_REPAIR_SPENT="$(awk -v s="${AIF_WORK_REPAIR_SPENT:-0}" -v c="$(_aif_work_envelope_cost "$copy" "$out")" 'BEGIN { printf "%.4f", s + c }')"
    rm -f "$out"
    # What the copy staged — the cost row, the kept envelope — belongs to this
    # run's record, not to a directory about to be deleted.
    if [ -f "$copy/.aif/tmp/meter-$ticket.jsonl" ]; then
      mkdir -p "$wt/.aif/tmp"
      cat "$copy/.aif/tmp/meter-$ticket.jsonl" >>"$wt/.aif/tmp/meter-$ticket.jsonl"
      rm -f "$copy/.aif/tmp/meter-$ticket.jsonl"
    fi
    if [ -d "$copy/.aif/tmp/stations-$ticket" ]; then
      mkdir -p "$wt/.aif/tmp/stations-$ticket"
      cp "$copy/.aif/tmp/stations-$ticket"/*.json "$wt/.aif/tmp/stations-$ticket/" 2>/dev/null || true
    fi

    rc=0
    verdict="$(aif_gate_run "$copy" verify-red "$cwork")" || rc=$?
    reason="$(printf '%s' "$verdict" | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^[[:space:]]*$' | sed -n 1p)"
    case "$rc" in
      0) aif_ledger_gate "$work" verify-red pass tests.lock.json "$(aif_sha256 "$cwork/tests.lock.json")" \
        "$(aif_sha256 "$(aif_gate_path "$copy" verify-red)")" "repair $repairs: $reason" ;;
      1) aif_ledger_gate "$work" verify-red fail "" "" "$(aif_sha256 "$(aif_gate_path "$copy" verify-red)")" "repair $repairs: $reason" ;;
      2) aif_ledger_gate "$work" verify-red spec "" "" "$(aif_sha256 "$(aif_gate_path "$copy" verify-red)")" "repair $repairs: $reason" ;;
      *) aif_ledger_gate "$work" verify-red error "" "" "$(aif_sha256 "$(aif_gate_path "$copy" verify-red)")" "repair $repairs: $reason" ;;
    esac
    _aif_gate_record_meter "$wt" "$work" 2>/dev/null || true
    if [ "$rc" -eq 0 ]; then
      _aif_work_say "gate" "tests admitted in the copy — $reason"
      break
    elif [ "$rc" -eq 1 ]; then
      complaint="REPAIR, again — the amended tests were REJECTED in the copy. The gate's complaints, verbatim — fix exactly these:
$(printf '%s' "$verdict" | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^$' | sed -n '1,40p')"
      _aif_work_say "gate" "tests rejected in the copy (repair attempt $n/$attempts_max) — retrying with the complaint"
    else
      AIF_WORK_REPAIR_WHY="verify-red could not admit the repaired tests (exit $rc):
$(printf '%s' "$verdict" | sed 's/\x1b\[[0-9;]*m//g' | sed -n '1,20p')"
      break
    fi
  done

  if [ -n "$AIF_WORK_REPAIR_WHY" ]; then
    rm -rf "${copy:?}"
    return 1
  fi

  # Back here: the oracle, and nothing of the implementation.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -f "$copy/$f" ]; then
      mkdir -p "$wt/$(dirname "$f")"
      cp "$copy/$f" "$wt/$f"
    fi
  done <<EOF
$test_files
EOF
  cp "$cwork/tests.lock.json" "$work/tests.lock.json"
  [ ! -f "$cwork/tests.note.json" ] || cp "$cwork/tests.note.json" "$work/tests.note.json"
  rm -rf "${copy:?}"

  # The commit holds the oracle and the ticket's record, never the code: the
  # implementation stays uncommitted, and the baseline green diffs it against
  # is this commit, which carries the tests it is now judged by.
  git -C "$wt" add -- "$AIF_TASKS_DIR/$ticket" >/dev/null 2>&1 || true
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$wt/$f" ] || continue
    git -C "$wt" add -- "$f" >/dev/null 2>&1 || true
  done <<EOF
$test_files
EOF
  if ! git -C "$wt" diff --cached --quiet 2>/dev/null; then
    git -C "$wt" -c user.email="aif@local" -c user.name="aif" \
      commit -q -m "aif: tests $ticket (repair $repairs)" >/dev/null 2>&1 || true
  fi
  # shellcheck disable=SC2016  # jq's variables, bound by --arg
  aif_run_update "$work" '.dispatch_base = $b | .regate = "implement"' \
    --arg b "$(git -C "$wt" rev-parse HEAD 2>/dev/null || printf '')"
  _aif_work_say "repair" "the oracle is back, committed; the implementation is judged again"
  return 0
}

# _aif_work_replan <wt> <ticket> <reason>
#
# The implement station declared, in its note, that the contract cannot hold
# the behaviour. Everything since the first plan dispatch is put back — the
# skeleton, the tests, the lock, the plan — and the plan station runs again
# with the declaration, in a tree exactly as it first saw it. Bounded per
# ticket by limits.replans_max: a contract that fails twice is a ticket for a
# human. rc 0 replanning: run.json is at stage plan · 1 not, AIF_WORK_REPLAN_WHY says why.
_aif_work_replan() {
  local wt="$1" ticket="$2" reason="$3" work project replans max plan_base
  AIF_WORK_REPLAN_WHY=""
  work="$(aif_task_dir "$wt" "$ticket")"
  project="$(aif_project_config "$wt")"
  max="$(jq -r '.limits.replans_max // 1' "$project")"
  replans="$(aif_run_get "$work" '.replans')"
  replans="${replans:-0}"
  if [ "$replans" -ge "$max" ]; then
    AIF_WORK_REPLAN_WHY="the implement station declares the contract cannot hold the behaviour, after $replans replan(s) (limits.replans_max) — the plan does not converge on this ticket:
$reason"
    return 1
  fi
  plan_base="$(aif_run_get "$work" '.plan_base')"
  if [ -z "$plan_base" ]; then
    AIF_WORK_REPLAN_WHY="the implement station declares the contract cannot hold the behaviour, and the run record has no plan baseline to replan from:
$reason"
    return 1
  fi
  replans=$((replans + 1))
  _aif_work_say "replan" "$replans/$max — the plan station, with the implementer's declaration"
  _aif_work_restore_since "$wt" "$plan_base" "^$AIF_TASKS_DIR/$ticket/(ledger\.json|run\.json|stations/)"
  rm -f "$work/implement.note.json" "$work/tests.note.json" "$work/tests.lock.json" "$work/plan-amendments.json"
  # shellcheck disable=SC2016  # jq's variables, bound by --argjson/--arg
  aif_run_update "$work" '.replans = $r | .stage = "plan" | .regate = null | .tests_base = null' --argjson r "$replans"
  AIF_WORK_REPLAN_COMPLAINT="REPLAN — the implement station declares that the contract this plan wrote cannot hold the behaviour the criteria ask for. Its words, verbatim:
$reason
Write the plan again, and the skeleton with it, so that the contract can. Everything since the first plan is gone from the tree; the ticket is unchanged."
  return 0
}

# _aif_work_report <root> <wt> <ticket> <status> <why> <started>
#
# The artifact the human reviews. Everything in it is read from files the run
# wrote — the ledger, the run record, the ticket, the plan — never narrated.
_aif_work_report() {
  local root="$1" wt="$2" ticket="$3" status="$4" why="$5" started="$6"
  local work ledger run report base diffstat="" mins checklist stations
  work="$(aif_task_dir "$wt" "$ticket")"
  ledger="$(aif_ledger_path "$work")"
  run="$(aif_run_path "$work")"
  report="$work/report.md"

  # Fold anything still staged (a station whose gate never got to run) so the
  # report and the ledger agree.
  _aif_gate_record_meter "$wt" "$work" 2>/dev/null || true

  # And move the kept transcripts in, now that no gate will diff the tree again.
  stations="$wt/.aif/tmp/stations-$ticket"
  if [ -d "$stations" ]; then
    mkdir -p "$work/stations"
    cp "$stations"/*.json "$work/stations/" 2>/dev/null || true
    rm -rf "$stations"
  fi

  base="$(jq -r '.base // "none"' "$run" 2>/dev/null)"
  if [ "$base" != "none" ]; then
    diffstat="$(git -C "$wt" diff --shortstat "$base" HEAD -- . ":(exclude)$AIF_TASKS_DIR" 2>/dev/null | sed 's/^ *//')"
  fi
  [ -n "$diffstat" ] || diffstat="no code changed"
  mins=$((($(date +%s) - started) / 60))
  checklist="$(aif_run_checklist "$work")"

  jq --arg st "$status" --arg why "$why" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '.status = $st | .why = (if $why == "" then null else $why end) | .finished_at = $at' \
    "$run" >"$run.tmp" && mv "$run.tmp" "$run"

  # Everything written here is markdown: the backticks are code spans, not
  # command substitution, and the single quotes are what keeps them that way.
  # shellcheck disable=SC2016
  {
    printf '# %s — %s\n\n' "$ticket" "$status"
    printf -- '- branch `%s` · %s · %s min · %s dispatch(es) · stage `%s`\n' \
      "$(jq -r '.branch' "$run")" "$diffstat" "$mins" \
      "$(jq -r '.dispatches' "$run")" "$(jq -r '.stage' "$run")"
    printf -- '- built against `ticket.md` sha256 `%s`\n' "$(jq -r '.ticket_sha256' "$run")"
    if [ -f "$work/ticket.md" ] && [ "$(aif_sha256 "$work/ticket.md")" != "$(jq -r '.ticket_sha256' "$run")" ]; then
      printf -- '- **the ticket changed after intake** — this run built the bytes above, not the current file\n'
    fi
    if [ -n "$why" ]; then
      printf '\n## Why it stopped\n\n%s\n' "$why"
    fi

    printf '\n## Stations\n\n'
    printf '| station | attempts | turns | output tokens | cost |\n|---|---|---|---|---|\n'
    jq -r '
      [ .entries[] | select(.station != null) ] as $rows
      | ( $rows | map(.station) | reduce .[] as $x ([]; if index($x) == null then . + [$x] else . end) ) as $names
      | $names[] as $n
      | ( $rows | map(select(.station == $n)) ) as $g
      | "| " + $n + " | " + ($g | length | tostring) + " | "
        + ($g | map(.num_turns // 0) | add | tostring) + " | "
        + ($g | map(.usage.output_tokens // 0) | add | tostring) + " | "
        + ( ($g | map(.cost_usd // empty) | add) as $c
            | if $c == null then "tokens only" else "$" + ($c | tostring) end ) + " |"
    ' "$ledger" 2>/dev/null
    printf '\n_Costs come from `.aif/prices.json`; a model missing there prints "tokens only". Tokens are always recorded. Each station'"'"'s own account of what it did is kept in `stations/`._\n'

    # The numbers the stability figure is computed from (docs/REBUILD-4.md
    # §0, §5): what the oracle held at the freeze, and which loops the run
    # took. Read from the lock and the run record, never narrated.
    printf '\n## Convergence\n\n'
    if [ -f "$work/tests.lock.json" ]; then
      jq -r '
        "- tests: " + ((.declared_files // []) | length | tostring) + " declared file(s), "
        + (if .collected_files == null then "collected not known (coarse)" else ((.collected_files | length | tostring) + " collected") end)
        + "; " + ((.covering // []) | length | tostring) + " red at the freeze, "
        + ((.green_at_freeze // []) | length | tostring) + " green at the freeze"
        + (if ((.red_with_tests // []) | length) > 0 then ", " + ((.red_with_tests | length) | tostring) + " pre-existing red with them" else "" end)' \
        "$work/tests.lock.json" 2>/dev/null
    else
      printf -- '- tests: nothing frozen\n'
    fi
    jq -r '"- loops: " + ((.repairs // 0) | tostring) + " repair(s) of the oracle, " + ((.replans // 0) | tostring) + " replan(s)"' "$run" 2>/dev/null

    # A station can end with a runner error and still be admitted: the gate
    # judges the artifacts, not the exit code. That is the intended behaviour
    # and it is invisible in the table above, so it gets its own section rather
    # than living only in the scrollback of whoever started the run.
    if [ "$(jq -r '(.station_errors // []) | length' "$run" 2>/dev/null)" != "0" ]; then
      printf '\n## Stations that ended with a runner error\n\n'
      printf 'The runner reported a failure for these dispatches. Their artifacts were still\n'
      printf 'judged by the gate — the gate is the verdict — so a station can appear here and\n'
      printf 'have been admitted anyway. Read it next to the diff.\n\n'
      jq -r '(.station_errors // [])[]
        | "- `" + .stage + "` attempt " + (.attempt | tostring) + " — " + .error' "$run" 2>/dev/null
    fi

    if [ -f "$work/plan.md" ]; then
      printf '\n## Decisions the plan made\n\n'
      aif_meta_json "$work/plan.md" | jq -r '
        (.decisions // []) | if length == 0 then "- none recorded" else
        .[] | "- **" + .id + "** " + .statement
          + "\n  - because: " + (.because // "—")
          + (if ((.rejected // "") | length) > 0 then "\n  - rather than: " + .rejected else "" end) end' 2>/dev/null
    fi
    printf '\n## Decided with the analyst\n\n'
    aif_meta_json "$work/ticket.md" | jq -r '
      (.decided // []) | if length == 0 then "- nothing was left open" else
      .[] | "- " + (if .by == "default" then "**by default, not by the human:** " else "" end)
        + .question + " → " + .answer
        + (if (.kind // "") == "architecture" then " _(architecture)_" else "" end) end' 2>/dev/null

    printf '\n## Not verified by this run\n\n'
    printf '%s' "$checklist" | jq -r '
      if length == 0
        then "- nothing recorded — every criterion was exercised, and the plan named no unvalidated dependency"
        else .[] | "- [ ] **" + .source + " " + .id + "** " + .text end' 2>/dev/null

    printf '\n## Gates\n\n'
    jq -r '[ .entries[] | select(.gate != null) ] | if length == 0 then "- none ran" else
      .[] | "- " + .gate + ": " + .result + (if (.reason // "") != "" then " — " + .reason else "" end) end' \
      "$ledger" 2>/dev/null
    printf '\n---\n_Written by `aif work`. Review the diff on the branch; merge when it is what you meant, or send the ticket back through the analyst with what was wrong._\n'
  } >"$report.tmp" && mv "$report.tmp" "$report"

  git -C "$wt" add -A "$AIF_TASKS_DIR/$ticket" >/dev/null 2>&1 || true
  if ! git -C "$wt" diff --cached --quiet 2>/dev/null; then
    git -C "$wt" -c user.email="aif@local" -c user.name="aif" \
      commit -q -m "aif: report $ticket ($status)" >/dev/null 2>&1 || true
  fi

  printf '\n'
  cat "$report"
  printf '\n%s%s%s\n' "$AIF_C_DIM" "${report#"$root"/}" "$AIF_C_RESET"
}

# _aif_work_loop <root> <max> <profile> <budget> <budget_off> <max_minutes>
#                <use_worktree> — drain Ready.
#
# One `aif work <card>` per card, as a child process: each run keeps its own
# traps, caps and exit code, and the single-ticket path above is not
# re-entered with half its globals set. The board is read again before every
# run, so a card the project manager moves while the loop runs is taken (or
# not) in the order the board has at that moment — queue policy stays theirs.
#
# Stops when Ready is empty, at --max-tickets, when a run cannot start at all
# (exit 3: the environment, not the card), after two runs in a row that did
# not build, or when a card is still at the top of Ready after its run —
# every run moves its card, so that last one means the run never got to the
# board, and taking it again would loop forever.
#
# Exit: 0 every ticket taken was built · 1 some were not · 3 stopped on the
# environment.
_aif_work_loop() {
  local root="$1" max="$2" profile="$3" budget="$4" budget_off="$5"
  local max_minutes="$6" use_worktree="$7"
  local next last="" rc taken=0 built=0 in_a_row=0 why="" env=0

  set --
  [ -z "$profile" ] || set -- "$@" --profile "$profile"
  if [ "$budget_off" -eq 1 ]; then
    set -- "$@" --no-budget
  elif [ -n "$budget" ]; then
    set -- "$@" --budget "$budget"
  fi
  [ -z "$max_minutes" ] || set -- "$@" --max-minutes "$max_minutes"
  [ "$use_worktree" -eq 1 ] || set -- "$@" --no-worktree

  while :; do
    if [ "$max" -gt 0 ] && [ "$taken" -ge "$max" ]; then
      why="--max-tickets $max reached"
      break
    fi
    next="$(aif_board_next_ready "$root")"
    if [ -z "$next" ]; then
      why="Ready is empty"
      break
    fi
    if [ "$next" = "$last" ]; then
      why="$next is still at the top of Ready after its run — the run never reached the board; not taking it again"
      break
    fi
    last="$next"
    taken=$((taken + 1))
    printf '\n%sloop%s %s — %s\n' "$AIF_C_BOLD" "$AIF_C_RESET" "$taken" "$next" >&2
    rc=0
    "$AIF_ROOT/bin/aif" work "$next" ${1+"$@"} || rc=$?
    case "$rc" in
      0)
        built=$((built + 1))
        in_a_row=0
        ;;
      3)
        why="$next could not start (exit 3) — the environment, not the card; the loop stops"
        env=1
        break
        ;;
      *)
        in_a_row=$((in_a_row + 1))
        if [ "$in_a_row" -ge 2 ]; then
          why="two runs in a row did not build ($next the last) — read the cards in Needs Human before spending on a third"
          break
        fi
        ;;
    esac
  done

  printf '\n%sloop%s %s taken, %s built — %s\n' "$AIF_C_BOLD" "$AIF_C_RESET" "$taken" "$built" "$why" >&2
  [ "$env" -eq 0 ] || exit 3
  [ "$taken" -eq "$built" ] || exit 1
  exit 0
}

aif_cmd_work() {
  local ticket="" profile="" budget="" max_minutes="" use_worktree=1 clean=0
  local loop=0 max_tickets=0
  # An empty budget means NO ceiling, here and everywhere below. budget_off
  # separates "the caller said no ceiling" from "the caller said nothing",
  # which is what lets --no-budget override a project that sets one.
  local budget_off=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --profile)
        shift
        profile="${1:-}"
        ;;
      --budget)
        shift
        budget="${1:-}"
        budget_off=0
        # Validated, because the failure is silent in the wrong direction: awk
        # reads a non-number as 0, and `spent > 0` is true at the first cent —
        # the run would stop after one station and blame the budget.
        case "$budget" in
          '' | *[!0-9.]* | *.*.* | .) aif_die "--budget takes a positive dollar amount, e.g. --budget 5 (for no ceiling: --no-budget)" ;;
        esac
        awk -v b="$budget" 'BEGIN { exit !(b > 0) }' ||
          aif_die "--budget must be greater than 0 (for no ceiling: --no-budget)"
        ;;
      --no-budget)
        budget=""
        budget_off=1
        ;;
      --max-minutes)
        shift
        max_minutes="${1:-}"
        ;;
      --no-worktree) use_worktree=0 ;;
      --clean) clean=1 ;;
      --loop) loop=1 ;;
      --max-tickets)
        shift
        max_tickets="${1:-}"
        case "$max_tickets" in
          '' | *[!0-9]* | 0) aif_die "--max-tickets takes a positive whole number" ;;
        esac
        ;;
      -h | --help)
        _aif_work_usage
        return 0
        ;;
      -*) aif_die "unknown option: $1" ;;
      *) ticket="$1" ;;
    esac
    shift
  done

  # --no-worktree keeps bypassPermissions and drops the disposable copy that
  # justified it (lib/runner_claude.sh). The usage text always said "only for a
  # checkout that is already disposable" and nothing enforced it
  # (docs/DEFECTS-3.md #11). Now the caller has to say so: CI jobs already
  # carry CI=1, and a harness sets AIF_DISPOSABLE=1 for its sandboxes.
  if [ "$use_worktree" -eq 0 ] && [ "$clean" -eq 0 ] &&
    [ -z "${CI:-}" ] && [ "${AIF_DISPOSABLE:-}" != "1" ]; then
    aif_die "--no-worktree runs every station with bypassPermissions in THIS checkout, and nothing here says it is disposable. In CI, CI=1 already does; anywhere else: AIF_DISPOSABLE=1 aif work ${ticket:-<ticket>} --no-worktree"
  fi

  local root
  root="$(aif_require_project)"

  if [ "$clean" -eq 1 ]; then
    [ -n "$ticket" ] || aif_die "usage: aif work <ticket> --clean"
    local wt_c="$root/$AIF_WORK_WORKTREES/$ticket"
    [ -e "$wt_c" ] || aif_die "no worktree for $ticket at ${wt_c#"$root"/}"
    git -C "$root" worktree remove --force "$wt_c" >/dev/null 2>&1 || rm -rf "$wt_c"
    git -C "$root" worktree prune >/dev/null 2>&1 || true
    printf '%sremoved%s %s — branch aif/%s is untouched\n' "$AIF_C_GREEN" "$AIF_C_RESET" "${wt_c#"$root"/}" "$ticket"
    return 0
  fi

  if [ "$loop" -eq 1 ]; then
    [ -z "$ticket" ] || aif_die "--loop takes no ticket: it drains the board's Ready column in the board's order"
    _aif_work_loop "$root" "$max_tickets" "$profile" "$budget" "$budget_off" "$max_minutes" "$use_worktree"
  fi
  [ "$max_tickets" -eq 0 ] || aif_die "--max-tickets only means something with --loop"

  if [ -z "$profile" ]; then
    if [ -f "$root/$AIF_PROFILE_STATE" ]; then
      profile="$(cat "$root/$AIF_PROFILE_STATE")"
    else
      aif_die "no profile — run 'aif init' or pass --profile"
    fi
  fi

  _aif_work_preflight "$root" "$profile"

  # No ticket named: the board decides. The top of Ready is the project
  # manager's order, and the worker consumes it — queue policy is theirs, the
  # queue is not.
  if [ -z "$ticket" ]; then
    ticket="$(aif_board_next_ready "$root")"
    [ -n "$ticket" ] || aif_die "nothing in the board's Ready column — write a ticket with /aif-ba, or name one: aif work <ticket>"
    _aif_work_say "board" "next in Ready: $ticket"
  fi

  # The checkout first, then the card. Cutting a worktree spends nothing, and
  # what has to be established in it — that the suite can run there at all —
  # is a preflight question: answered no, the run must not start, and a card
  # that never moved needs nothing put back.
  local wt fresh=0
  if [ "$use_worktree" -eq 1 ]; then
    # Decided here, not inside the helper: it runs in a $(…) and a flag it set
    # would die with the subshell.
    [ -e "$root/$AIF_WORK_WORKTREES/$ticket/.git" ] || fresh=1
    wt="$(_aif_work_worktree "$root" "$ticket")"
    [ "$fresh" -eq 0 ] || _aif_work_say "worktree" "cut ${wt#"$root"/} on aif/$ticket"
    _aif_work_ready_worktree "$root" "$wt" "$ticket" || exit 3
    # The stations read the WORKTREE's copy of the guide, and a worktree is cut
    # from HEAD: a guide written in the developer's checkout and never
    # committed is not here. Preflight saw the developer's copy; this is the
    # one the stations would be told to read.
    if [ ! -f "$(aif_guide_path "$wt")" ]; then
      aif_err "$AIF_GUIDE_FILE is not on branch aif/$ticket — it is uncommitted in your checkout, and the stations run in ${wt#"$root"/}, cut from HEAD. Nothing was spent."
      aif_err "Commit it (git add $AIF_GUIDE_FILE && git commit) and run again; a worktree cut before it existed is remade with: aif work $ticket --clean, then git branch -D aif/$ticket if the branch holds nothing yet"
      exit 3
    fi
  else
    wt="$root"
  fi
  _aif_work_say "worktree" "${wt#"$root"/}"

  # The card moves before anything is spent. A ticket handed over by id that
  # has no card yet gets one on the local board — the worker is the consumer,
  # and a ticket named by hand is implicitly ready; on a trello board the card
  # IS the ticket, so it has to be there already.
  if [ "$(aif_board_kind "$root")" = "local" ] && [ ! -f "$(aif_board_local_dir "$root")/$ticket.json" ] &&
    [ -f "$(aif_task_dir "$root" "$ticket")/ticket.md" ]; then
    (aif_board_create "$root" "$(aif_task_dir "$root" "$ticket")/ticket.md" ready >/dev/null) || true
  fi
  if ! (aif_board_move "$root" "$ticket" in_progress >/dev/null); then
    aif_err "could not move $ticket to In Progress on the board — nothing was spent."
    exit 3
  fi

  # From here the card says work is happening, and every way out of this
  # function has to end that claim. The handler is armed rather than written
  # inline so that a library taking a trap of its own puts it back instead of
  # clearing it (lib/common.sh). Its subject travels in globals: a trap fires
  # with no argument, and on EXIT the locals may already be gone.
  AIF_WORK_ROOT="$root"
  AIF_WORK_CARD="$ticket"
  AIF_WORK_SETTLED=0
  aif_trap_arm "_aif_work_abandon"

  local intake_rc=0
  AIF_WORK_NOT_READY=""
  _aif_work_intake "$root" "$wt" "$ticket" || intake_rc=$?
  if [ "$intake_rc" -ne 0 ]; then
    # Not ready, or no ticket at all. Either way nothing has been spent, and
    # the card goes where a human will see it with the reason attached.
    local nr="$wt/.aif/tmp/not-ready-$ticket.md"
    mkdir -p "$(dirname "$nr")" 2>/dev/null || true
    {
      printf '# %s — not ready\n\n' "$ticket"
      printf 'The worker refused the ticket at intake and spent nothing. Each line below\n'
      printf 'is a question for the analyst (/aif-ba), not a defect in the build:\n\n'
      printf '%s\n' "${AIF_WORK_NOT_READY:-the ticket does not exist in this checkout}" | sed 's/^/    /'
    } >"$nr"
    (AIF_BOARD_BY="aif work" aif_board_comment "$root" "$ticket" "$nr" >/dev/null) || true
    AIF_WORK_SETTLED=1
    (aif_board_move "$root" "$ticket" needs_human >/dev/null) || true
    rm -f "$nr"
    _aif_work_say "board" "$ticket → needs_human, the gate's questions posted"
    exit 1
  fi

  local work project attempts_max run_max dispatches_max started
  work="$(aif_task_dir "$wt" "$ticket")"
  project="$(aif_project_config "$wt")"
  # 16, as the templates say since the stage gained its two loops (a repair,
  # a replan) on top of the three stations' retries (docs/REBUILD-4.md §2.4).
  # A project.json from before the key ran the new stage on the old 12
  # (docs/DEFECTS-8.md #4); the fallback is now the number the stage was
  # budgeted for.
  dispatches_max="$(jq -r '.limits.run_dispatches_max // 16' "$project")"
  [ -n "$max_minutes" ] || max_minutes="$(jq -r '.limits.run_max_minutes // 120' "$project")"
  # No default. A dollar ceiling that nobody chose is worse than none: under
  # subscription auth the runner reports $0 and .aif/prices.json ships empty,
  # so the old default of 20 could not fire on the commonest setup — it read
  # as a guarantee and was not one. Now it is off unless the project or the
  # caller names a number, and when it IS named the run says so on its first
  # line. The wall clock and the dispatch cap are the caps that always apply.
  if [ "$budget_off" -eq 1 ]; then
    budget=""
  elif [ -z "$budget" ]; then
    budget="$(jq -r '.limits.run_budget_usd // empty' "$project")"
  fi
  local budget_say="off"
  [ -z "$budget" ] || budget_say="\$$budget"
  run_max=$((max_minutes * 60))
  started="$(date +%s)"

  printf '\n%swork%s %s · profile %s · budget %s · ≤%s min · ≤%s dispatches\n\n' \
    "$AIF_C_BOLD" "$AIF_C_RESET" "$ticket" "$profile" "$budget_say" "$max_minutes" \
    "$dispatches_max" >&2

  # The loop. The run record says which stage is next and the station's own
  # agent file says what checks it; the worker keeps only what is true of THIS
  # invocation — how many times it has dispatched, and how much it has spent.
  # Note on the run-record filters below: every $-sign in them is jq's variable,
  # bound by the --arg flags that follow the filter. The single quotes are what
  # keeps the shell out of them, hence a disable on each.
  local stage agent expects complaint="" status="" why="" gate_out
  local dispatches=0 spent=0 attempts out rc station_err tool_out budget_left
  local regate skip_dispatch prev_sha="" prev_stage="" this_sha replan_why
  cd "$wt" || aif_die "cannot enter $wt"
  mkdir -p "$wt/.aif/tmp"
  gate_out="$wt/.aif/tmp/gate-$ticket.out"

  while :; do
    if [ $(($(date +%s) - started)) -gt "$run_max" ]; then
      status="stopped"
      why="wall clock: past $max_minutes minutes. What was accepted is committed on the branch; nothing after it is."
      break
    fi
    if [ "$dispatches" -ge "$dispatches_max" ]; then
      status="stopped"
      why="dispatch cap: $dispatches_max station runs (limits.run_dispatches_max). The run is grinding, not converging — the ticket probably does not say enough."
      break
    fi

    stage="$(aif_run_get "$work" '.stage')"
    if [ "$stage" = "done" ] || [ -z "$stage" ]; then
      status="built"
      break
    fi

    agent="$(aif_station_agent "$wt" "$stage" "$work" 2>/dev/null)"
    [ -n "$agent" ] || {
      status="stopped"
      why="no station is installed for the stage '$stage' — run 'aif init'"
      break
    }
    attempts_max="$(_aif_work_attempts_max "$wt" "$stage" "$project")"

    # After a repair the implementation is already in the tree and what moved
    # is the oracle it is judged against: the gates run, nothing is dispatched.
    skip_dispatch=0
    regate="$(aif_run_get "$work" '.regate')"
    if [ -n "$regate" ] && [ "$regate" = "$stage" ]; then
      skip_dispatch=1
      # shellcheck disable=SC2016  # jq's variable
      aif_run_update "$work" '.regate = null'
      _aif_work_say "regate" "$stage — the oracle was repaired; the implementation is judged again, not dispatched"
    fi

    attempts="$(aif_run_attempts "$work" "$stage")"
    if [ "$skip_dispatch" -eq 0 ] && [ "$attempts" -ge "$attempts_max" ]; then
      status="stopped"
      why="$stage was rejected $attempts time(s) in a row (its attempts cap: max_attempts in its aif:meta, else limits.attempts_max). Last complaint:
$complaint"
      break
    fi

    if [ "$skip_dispatch" -eq 0 ]; then
      expects="$(aif_station_meta "$wt" "$stage" 2>/dev/null | jq -r '.expects // ""')"
      [ -z "$expects" ] || _aif_work_say "expects" "$expects"

      dispatches=$((dispatches + 1))
      # dispatch_base: HEAD as it stands now, for scope and green to judge
      # against. A station with Bash can commit; after it does, "the last commit"
      # is its own, and a gate diffing against that sees nothing
      # (docs/DEFECTS-3.md #8, aif_g_dispatch_base in the gates' _lib.sh).
      # plan_base and tests_base: the tree each of those stations FIRST saw,
      # which is where a replan puts the tree back, and where a repair's copy
      # measures the pre-existing suite from.
      # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags below
      aif_run_update "$work" \
        '.dispatches = $d | .attempts[$s] = ((.attempts[$s] // 0) + 1) | .dispatch_base = $b
         | (if $s == "plan" then .plan_base = (.plan_base // $b) else . end)
         | (if $s == "tests" then .tests_base = (.tests_base // $b) else . end)' \
        --arg s "$stage" --argjson d "$dispatches" \
        --arg b "$(git -C "$wt" rev-parse HEAD 2>/dev/null || printf '')"

      # The two %f formats — here and on the spend below — print a dot because
      # bin/aif pins LC_NUMERIC=C. One goes to the station as dollars left, the
      # other into jq as a JSON number; a decimal comma is wrong in both.
      out="$(mktemp "${TMPDIR:-/tmp}/aif-env-XXXXXX")"
      rc=0
      # Empty when there is no ceiling, and the runner is then invoked without
      # --max-budget-usd at all. Computing it anyway would hand the station the
      # 0.01 floor below — a one-cent cap in place of no cap.
      budget_left=""
      if [ -n "$budget" ]; then
        budget_left="$(awk -v b="$budget" -v s="$spent" 'BEGIN { r = b - s; if (r < 0.01) r = 0.01; printf "%.2f", r }')"
      fi
      _aif_work_dispatch "$wt" "$ticket" "$stage" "$agent" "$complaint" \
        "$budget_left" "$out" || rc=$?
      if [ "$rc" -eq 3 ]; then
        rm -f "$out"
        status="stopped"
        why="the runner could not run the $stage station (no envelope) — the environment, not the ticket."
        break
      fi
      _aif_work_keep_envelope "$wt" "$ticket" "$dispatches" "$stage" "$out"
      spent="$(awk -v s="$spent" -v c="$(_aif_work_envelope_cost "$wt" "$out")" 'BEGIN { printf "%.4f", s + c }')"
      # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags below
      aif_run_update "$work" '.spent_usd = $s' --argjson s "$spent"
      if ! "aif_runner_${AIF_PROFILE_RUNNER}_result_ok" "$out"; then
        station_err="$("aif_runner_${AIF_PROFILE_RUNNER}_result_error" "$out")"
        # A station that ended badly may still have left a usable artifact on
        # disk, and the GATE decides, not the runner's exit code. That is
        # deliberate — but on its own it reads as a contradiction: "ended with an
        # error" followed on the next line by "admitted", with nothing outside
        # the scrollback remembering it happened. So say which of the two is the
        # verdict, and put the error in the run record for the report to carry.
        _aif_work_say "station" "$stage ended with an error: $station_err"
        _aif_work_say "station" "  the gate below judges the artifacts it left; the runner's exit is not the verdict"
        # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags below
        aif_run_update "$work" \
          '.station_errors = ((.station_errors // []) + [{ stage: $s, attempt: $a, error: $e }])' \
          --arg s "$stage" --arg e "$station_err" --argjson a "$((attempts + 1))"
      fi
      rm -f "$out"

      if [ -n "$budget" ] && awk -v s="$spent" -v b="$budget" 'BEGIN { exit !(s > b) }'; then
        status="stopped"
        why="budget: spent \$$spent of \$$budget — each station priced from its tokens where .aif/prices.json knows the model, else as the runner reported it."
        break
      fi

      # Before any gate: a station that moved a dependency manifest or lockfile
      # gets its dependencies installed again from the lock, and one whose files
      # cannot be installed is sent back like a rejection — recorded as the
      # "prepare" verdict, retried with prepare's own words, capped the same way.
      if ! _aif_work_reprepare "$root" "$wt" "$work"; then
        complaint="$AIF_WORK_REPREPARE"
        _aif_gate_record_meter "$wt" "$work" 2>/dev/null || true
        aif_ledger_gate "$work" prepare fail "" "" "" \
          "$(printf '%s' "$AIF_WORK_REPREPARE" | sed -n 1p)"
        _aif_work_say "prepare" "$stage rejected (attempt $((attempts + 1))/$attempts_max) — the dependencies it left do not install; retrying with prepare's output"
        continue
      fi

      # The tool writes the provenance the station was never asked to carry.
      # Its failure is the tool's, never the station's — and it used to be
      # silent: an unstamped plan is rejected by verify-red as "bound to a
      # different ticket", the station rewrites the same plan, and the loop
      # repeats to the cap, billing a tool defect to the human as opus retries
      # (docs/DEFECTS-3.md #7). So it stops, and says whose fault it was.
      if ! tool_out="$("$AIF_ROOT/bin/aif" _record "$stage" "$ticket" 2>&1)"; then
        status="stopped"
        why="aif _record failed after the $stage station — the tool, not the station, and no gate was run:
$(printf '%s' "$tool_out" | sed 's/\x1b\[[0-9;]*m//g' | sed -n '1,10p')"
        break
      fi

      # The implementer's declaration that the contract cannot hold the
      # behaviour: a replan, bounded, before any gate judges code written
      # against a contract its author says is wrong (docs/REBUILD-4.md §2.3).
      if [ "$stage" = "implement" ] && [ -f "$work/implement.note.json" ]; then
        replan_why="$(jq -r '.replan // empty' "$work/implement.note.json" 2>/dev/null)"
        if [ -n "$replan_why" ]; then
          _aif_gate_record_meter "$wt" "$work" 2>/dev/null || true
          if _aif_work_replan "$wt" "$ticket" "$replan_why"; then
            aif_ledger_gate "$work" replan pass "" "" "" "the implementer declares the contract cannot hold the behaviour — replanning"
            complaint="$AIF_WORK_REPLAN_COMPLAINT"
            prev_sha=""
            continue
          fi
          aif_ledger_gate "$work" replan fail "" "" "" "$(printf '%s' "$AIF_WORK_REPLAN_WHY" | sed -n 1p)"
          status="stopped"
          why="$AIF_WORK_REPLAN_WHY"
          break
        fi
      fi
    fi

    rc=0
    "$AIF_ROOT/bin/aif" _gate "$stage" "$ticket" >"$gate_out" 2>&1 || rc=$?
    case "$rc" in
      0)
        _aif_work_say "gate" "$stage admitted — $(grep -m1 '✓' "$gate_out" | sed 's/.*✓ //')"
        # The commit seals the verdict and is the next station's baseline. One
        # that did not happen used to be invisible until scope rejected the
        # implementation for "touching" the tests the previous commit should
        # have carried (docs/DEFECTS-3.md #7).
        if ! tool_out="$("$AIF_ROOT/bin/aif" _commit "$stage" "$ticket" 2>&1)"; then
          status="stopped"
          why="aif _commit failed after $stage was admitted — the tool, not the station. The verdict is recorded; the commit that seals it is not, and the next station's baseline would be wrong:
$(printf '%s' "$tool_out" | sed 's/\x1b\[[0-9;]*m//g' | sed -n '1,10p')"
          break
        fi
        complaint=""
        prev_sha=""
        # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags below
        aif_run_update "$work" '.stage = $n' --arg n "$(aif_run_next "$stage")"
        ;;
      1)
        # sed -n, not head: a gate's output is not bounded, and a head that
        # leaves early under set -e would end the run at the moment of the
        # rejection it was quoting (docs/DEFECTS-5.md #3).
        complaint="$(grep -v '^$' "$gate_out" | sed 's/\x1b\[[0-9;]*m//g' | sed -n '1,40p')"
        # The convergence rule: the same complaint twice in a row is a station
        # that cannot act on what it is told, and a third attempt is the same
        # coin again. Compared as the whole set of problems, with the numbers
        # the gates count removed, so "3 problem(s)" against "2 problem(s)" is
        # progress and the same three are not (docs/REBUILD-4.md §2.4).
        this_sha="$(printf '%s' "$complaint" | sed 's/[0-9]//g; s/[[:space:]]\{1,\}/ /g' | aif_sha256_stdin)"
        if [ "$prev_stage" = "$stage" ] && [ "$prev_sha" = "$this_sha" ]; then
          status="stopped"
          why="$stage was rejected with the same complaint twice in a row — the station cannot act on it, and a third attempt is the same again. The complaint:
$complaint"
          break
        fi
        prev_stage="$stage"
        prev_sha="$this_sha"
        _aif_work_say "gate" "$stage rejected (attempt $((attempts + 1))/$attempts_max) — retrying with the complaint"
        ;;
      2)
        # The ticket's: a criterion already true, unfalsifiable, in conflict,
        # undecided. Nothing is retried; the analyst gets the gate's lines.
        status="spec"
        why="$(sed 's/\x1b\[[0-9;]*m//g' "$gate_out" | grep -v '^[[:space:]]*$' | sed -n '1,30p')"
        break
        ;;
      4)
        # The oracle's: the tests station repairs it in a copy without the
        # implementation, and the implementation is judged again.
        budget_left=""
        if [ -n "$budget" ]; then
          budget_left="$(awk -v b="$budget" -v s="$spent" 'BEGIN { r = b - s; if (r < 0.01) r = 0.01; printf "%.2f", r }')"
        fi
        AIF_WORK_REPAIR_DISPATCHES=0
        AIF_WORK_REPAIR_SPENT=0
        rc=0
        _aif_work_repair "$root" "$wt" "$ticket" \
          "$(sed 's/\x1b\[[0-9;]*m//g' "$gate_out" | grep -v '^[[:space:]]*$' | sed -n '1,40p')" \
          "$budget_left" "$dispatches" || rc=$?
        dispatches=$((dispatches + AIF_WORK_REPAIR_DISPATCHES))
        spent="$(awk -v s="$spent" -v c="$AIF_WORK_REPAIR_SPENT" 'BEGIN { printf "%.4f", s + c }')"
        # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags below
        aif_run_update "$work" '.dispatches = $d | .spent_usd = $s' --argjson d "$dispatches" --argjson s "$spent"
        if [ "$rc" -ne 0 ]; then
          status="stopped"
          why="$AIF_WORK_REPAIR_WHY"
          break
        fi
        complaint=""
        prev_sha=""
        ;;
      3)
        # The environment, or a defect no loop in the stage reaches. The loop
        # stops and the gate's own words are the explanation; this line no
        # longer overrides them with a guess.
        status="stopped"
        why="a gate could not render a verdict on $stage, so the run stopped rather than
retrying a station that cannot fix what it is being rejected for. The gate says
which it is:
$(sed 's/\x1b\[[0-9;]*m//g' "$gate_out" | sed -n '1,20p')"
        break
        ;;
      *)
        status="stopped"
        why="aif _gate $stage exited $rc:
$(head -20 "$gate_out")"
        break
        ;;
    esac
  done
  rm -f "$gate_out"

  # Still armed: the report reads the ledger, the run record and the plan, and
  # a failure in any of that is exactly the case where the card must not be
  # left saying the work is under way.
  _aif_work_report "$root" "$wt" "$ticket" "$status" "$why" "$started"

  # The report goes where the human looks — the card — and the card moves to
  # where the human decides: Review when it is built, Needs Human when it is
  # not. Loud on failure, with the exact command to do it by hand; the work is
  # on the branch either way, and the exit code says what the work is.
  local col report_path
  report_path="$work/report.md"
  col=review
  [ "$status" = "built" ] || col=needs_human
  if ! (AIF_BOARD_BY="aif work" aif_board_comment "$root" "$ticket" "$report_path" >/dev/null); then
    aif_warn "could not post the report to the board — run: aif board comment $ticket ${report_path#"$root"/}"
  fi
  if ! (aif_board_move "$root" "$ticket" "$col" >/dev/null); then
    aif_warn "could not move $ticket to $col on the board — run: aif board move $ticket $col"
  else
    _aif_work_say "board" "$ticket → $col, report posted"
  fi
  AIF_WORK_SETTLED=1
  [ "$status" = "built" ]
}
