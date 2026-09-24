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
#               complaint in the prompt, up to limits.attempts_max — never a
#               conversation
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

  Every transition goes through the board (aif board): the card moves to In
  Progress when the run starts, and to Review — or Needs Human, with the
  report as a comment — when it ends.

  --profile P        which (set, runner, model) profile; default: the project's
  --budget USD       stop past this spend. Each station is priced from its
                     tokens where .aif/prices.json knows the model, else as the
                     runner reported it — under subscription auth that is \$0
  --max-minutes N    stop past this wall clock (default limits.run_max_minutes, 120)
  A fresh worktree holds tracked files only. "prepare" in .aif/project.json
  (npm ci, bundle install) runs once after it is cut, and the suite is then
  probed THERE before anything is spent — a checkout that cannot run the
  suite is refused, not built against.

  --no-worktree      run in the current checkout instead of a worktree. Every
                     station then runs with bypassPermissions HERE, so the
                     checkout must already be disposable: set CI=1 (a CI job
                     has it) or AIF_DISPOSABLE=1 to say so. Refused otherwise
  --clean            remove the ticket's worktree and stop

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
  max_turns="$(jq -r '.limits.station_max_turns // 30' "$project" 2>/dev/null)"
  [ -n "$model" ] || model="sonnet"
  [ -n "$tools" ] || tools="Read,Grep,Glob,Write,Edit"

  prompt="Ticket $ticket. Your working directory is the project root. Follow your instructions exactly: read the inputs they name under $AIF_TASKS_DIR/$ticket/ and produce what they specify, nothing else. Nobody will answer a question — decide from the ticket and the repository, and record what you decided in the fields your instructions provide for it."
  if [ -n "$complaint" ]; then
    prompt="$prompt

The previous attempt was REJECTED. The gate's complaints, verbatim — fix exactly these, and change nothing that was not complained about:
$complaint"
  fi

  sys="$(mktemp "${TMPDIR:-/tmp}/aif-sys-XXXXXX")"
  err="$(mktemp "${TMPDIR:-/tmp}/aif-err-XXXXXX")"
  aif_meta_body "$wt/.claude/agents/$agent.md" >"$sys"

  # The guard hook reads this: a station may write only what its station owns
  # (sets/claude/hooks/guard.sh).
  export AIF_STATION="$station"

  _aif_work_say "station" "$station · $agent · $model · ≤$max_turns turns"
  if [ -n "${AIF_WORK_STATION_CMD:-}" ]; then
    "$AIF_WORK_STATION_CMD" "$station" "$ticket" "$wt" "$sys" "$prompt" "$model" \
      "$max_turns" "$budget_left" "$tools" "$out" "$err" || rc=$?
  else
    "aif_runner_${AIF_PROFILE_RUNNER}_station" "$wt" "$sys" "$prompt" "$model" \
      "$max_turns" "$budget_left" "$tools" "$out" "$err" || rc=$?
  fi
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

aif_cmd_work() {
  local ticket="" profile="" budget="" max_minutes="" use_worktree=1 clean=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --profile)
        shift
        profile="${1:-}"
        ;;
      --budget)
        shift
        budget="${1:-}"
        ;;
      --max-minutes)
        shift
        max_minutes="${1:-}"
        ;;
      --no-worktree) use_worktree=0 ;;
      --clean) clean=1 ;;
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
  attempts_max="$(jq -r '.limits.attempts_max // 3' "$project")"
  dispatches_max="$(jq -r '.limits.run_dispatches_max // 12' "$project")"
  [ -n "$max_minutes" ] || max_minutes="$(jq -r '.limits.run_max_minutes // 120' "$project")"
  [ -n "$budget" ] || budget="$(jq -r '.limits.run_budget_usd // 20' "$project")"
  run_max=$((max_minutes * 60))
  started="$(date +%s)"

  printf '\n%swork%s %s · profile %s · budget $%s · ≤%s min\n\n' \
    "$AIF_C_BOLD" "$AIF_C_RESET" "$ticket" "$profile" "$budget" "$max_minutes" >&2

  # The loop. The run record says which stage is next and the station's own
  # agent file says what checks it; the worker keeps only what is true of THIS
  # invocation — how many times it has dispatched, and how much it has spent.
  # Note on the run-record filters below: every $-sign in them is jq's variable,
  # bound by the --arg flags that follow the filter. The single quotes are what
  # keeps the shell out of them, hence a disable on each.
  local stage agent expects complaint="" status="" why="" gate_out
  local dispatches=0 spent=0 attempts out rc station_err tool_out
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

    attempts="$(aif_run_attempts "$work" "$stage")"
    if [ "$attempts" -ge "$attempts_max" ]; then
      status="stopped"
      why="$stage was rejected $attempts time(s) in a row (limits.attempts_max). Last complaint:
$complaint"
      break
    fi

    expects="$(aif_station_meta "$wt" "$stage" 2>/dev/null | jq -r '.expects // ""')"
    [ -z "$expects" ] || _aif_work_say "expects" "$expects"

    dispatches=$((dispatches + 1))
    # dispatch_base: HEAD as it stands now, for scope and green to judge
    # against. A station with Bash can commit; after it does, "the last commit"
    # is its own, and a gate diffing against that sees nothing
    # (docs/DEFECTS-3.md #8, aif_g_dispatch_base in the gates' _lib.sh).
    # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags below
    aif_run_update "$work" \
      '.dispatches = $d | .attempts[$s] = ((.attempts[$s] // 0) + 1) | .dispatch_base = $b' \
      --arg s "$stage" --argjson d "$dispatches" \
      --arg b "$(git -C "$wt" rev-parse HEAD 2>/dev/null || printf '')"

    # The two %f formats — here and on the spend below — print a dot because
    # bin/aif pins LC_NUMERIC=C. One goes to the station as dollars left, the
    # other into jq as a JSON number; a decimal comma is wrong in both.
    out="$(mktemp "${TMPDIR:-/tmp}/aif-env-XXXXXX")"
    rc=0
    _aif_work_dispatch "$wt" "$ticket" "$stage" "$agent" "$complaint" \
      "$(awk -v b="$budget" -v s="$spent" 'BEGIN { r = b - s; if (r < 0.01) r = 0.01; printf "%.2f", r }')" \
      "$out" || rc=$?
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

    if awk -v s="$spent" -v b="$budget" 'BEGIN { exit !(s > b) }'; then
      status="stopped"
      why="budget: spent \$$spent of \$$budget — each station priced from its tokens where .aif/prices.json knows the model, else as the runner reported it."
      break
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
        # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags below
        aif_run_update "$work" '.stage = $n' --arg n "$(aif_run_next "$stage")"
        ;;
      1)
        # sed -n, not head: a gate's output is not bounded, and a head that
        # leaves early under set -e would end the run at the moment of the
        # rejection it was quoting (docs/DEFECTS-5.md #3).
        complaint="$(grep -v '^$' "$gate_out" | sed 's/\x1b\[[0-9;]*m//g' | sed -n '1,40p')"
        _aif_work_say "gate" "$stage rejected (attempt $((attempts + 1))/$attempts_max) — retrying with the complaint"
        ;;
      3)
        # Not always the environment. A gate also answers 3 when the defect is
        # real but lies in an artifact THIS station may not touch — a frozen
        # test file, say — where retrying is not merely wasteful, it is
        # unsatisfiable. Either way the loop stops and the gate's own words are
        # the explanation; this line no longer overrides them with a guess.
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
