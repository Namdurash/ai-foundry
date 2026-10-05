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
#   claim       the run lock — one worker per ticket on this machine — and
#               then the card, In Progress before the checkout is cut: the
#               board shows the card taken from the moment it is, and every
#               way out after that ends with it in Review, or in Needs Human
#               with a comment whose first line says why
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
# Exit: 0 built · 1 stopped, needs a human (the card's comment and the report
# say why) · 3 the environment cannot run a ticket (nothing was spent; a card
# already taken is in Needs Human saying what) · 130 / 143 stopped by Ctrl-C,
# by `aif work <ID> --stop` or by a TERM (the card says which).

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
    aif work OPES-52 --stop     stop the worker building it, from any terminal
    aif work --loop             every card in Ready, in the board's order, two at a time

  Every transition goes through the board (aif board). The card moves to In
  Progress first, before the checkout is cut, and ends in Review with the
  report as a comment — or in Needs Human with a comment whose first line
  says why: blocked: ticket | run | environment | stopped. One worker builds
  a ticket at a time on this machine; a second is refused, nothing spent.

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
  --stop             stop the run building this ticket on this machine, the
                     way its own Ctrl-C would: the station is ended, and the
                     card goes to Needs Human saying who stopped it. Back in
                     Ready, it resumes where it stopped
  --loop             build every card in Ready, in the board's order, each in a
                     worktree of its own, until Ready is empty. Workers start
                     one after another, each once the last one's worktree is
                     ready. Takes no new card when a run cannot start, or after
                     two that did not build — two cards in Needs Human usually
                     mean the problem is not the cards. Ctrl-C takes no new card
                     and lets the runs in flight finish; Ctrl-C again stops them.
                     --stop on one run stops that one, and its slot goes on.
                     Each worker's output is in .aif/tmp/loop-<when>/<ID>.log
  --parallel N       with --loop: N tickets at once (default 2; 1 with
                     --no-worktree, which builds in this checkout)
  --no-tui           with --loop: lines, not the dashboard. On a terminal the
                     loop draws one — the loop in the middle, each worker
                     around it with its station, model, progress and last
                     verdict; keys: 1-9 select a worker, s stop it, l its log,
                     q no new cards. Anywhere else it prints lines anyway
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

# _aif_work_abandon <EXIT|INT|TERM> — the card stops claiming that work is
# happening, and says why.
#
# Armed for EXIT, INT and TERM the moment the run lock is taken, and it has to
# cover all three. Ctrl-C and a supervisor's TERM are the obvious two; the
# common one is neither — it is any `aif_die` or `set -e` failure between the
# claim and the report, which used to leave the card In Progress with nobody
# working on it. That is the same defect as a meter that quietly did not fire,
# and for one release the handler meant to prevent it was disarmed by the
# first ledger write of every run (docs/DEFECTS.md 3.1–3.3).
#
# It used to move the card and say nothing: whoever opened Needs Human found a
# card with no reason on it, and the reason was in the scrollback of whoever
# had started the run. It posts one now (_aif_work_block) — who stopped the
# run and during which stage, or the last error the worker printed.
#
# Idempotent, and silent once the run has settled the card itself; the run
# lock is released either way. Where it acts it exits 130 for an INT, 143 for
# a TERM and 1 for an exit — a run nobody finished IS "stopped, needs a
# human", which is what 1 means here.
_aif_work_abandon() {
  local rc_in=$? sig="${1:-EXIT}" code=1 kind why stage who
  # `aif work <ID> --stop` waits for this: once the handler runs, the stop has
  # landed, and nothing under the worker is signalled again.
  [ -z "${AIF_WORK_LOCK:-}" ] || : >"$AIF_WORK_LOCK/ack" 2>/dev/null || true
  case "$sig" in
    INT) code=130 ;;
    TERM) code=143 ;;
  esac
  if [ "${AIF_WORK_SETTLED:-0}" = "0" ] && [ -n "${AIF_WORK_CARD:-}" ]; then
    AIF_WORK_SETTLED=1
    stage="${AIF_WORK_PHASE:-run}"
    if [ "$stage" = "run" ] && [ -n "${AIF_WORK_WORK:-}" ]; then
      stage="$(aif_run_get "$AIF_WORK_WORK" '.stage' 2>/dev/null)" || stage=""
      [ -n "$stage" ] || stage="run"
    fi
    if [ -n "${AIF_WORK_LOCK:-}" ] && [ -f "$AIF_WORK_LOCK/stop" ]; then
      who="$(sed -n 1p "$AIF_WORK_LOCK/stop" 2>/dev/null)"
      kind=stopped
      why="by ${who:-someone} (aif work $AIF_WORK_CARD --stop), during $stage"
    elif [ "$sig" = "INT" ]; then
      kind=stopped
      why="by Ctrl-C, during $stage"
    elif [ "$sig" = "TERM" ]; then
      kind=stopped
      why="by a TERM signal, during $stage"
    else
      # Before intake no station has run: what stopped it is the machine.
      case "${AIF_WORK_PHASE:-}" in
        claim | worktree | intake) kind=environment ;;
        *) kind=run ;;
      esac
      why="the worker exited (code $rc_in) during $stage"
      [ -z "${AIF_LAST_ERR:-}" ] || why="$why; the last error it printed: $AIF_LAST_ERR"
    fi
    _aif_work_block "$AIF_WORK_ROOT" "$AIF_WORK_CARD" "$kind" "$why" "" || true
    printf '\n%s did not finish — moved to needs_human, blocked: %s %s; the branch keeps what was accepted\n' \
      "$AIF_WORK_CARD" "$kind" "$why" >&2
    _aif_work_unlock
    exit "$code"
  fi
  _aif_work_unlock
  case "$sig" in
    INT | TERM) exit "$code" ;;
  esac
  return 0
}

# _aif_work_phase <claim|worktree|intake|run|report> — where this run has got
# to: for the exit handler, which says it on the card, and — through the run
# lock — for a loop deciding when to start its next worker.
_aif_work_phase() {
  AIF_WORK_PHASE="$1"
  [ -z "${AIF_WORK_LOCK:-}" ] || printf '%s\n' "$1" >"$AIF_WORK_LOCK/phase" 2>/dev/null || true
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  _aif_work_live '.phase = $p' --arg p "$1"
}

# _aif_work_live <jq-filter> [jq args…] — this run's live state, for the loop's
# dashboard (lib/tui.sh): the stage and attempt, the model, the dispatches and
# tokens so far, the last verdict — kept in the run lock beside the phase and
# rewritten as the run moves. A view, never the record: nothing else reads it,
# and failing to write it is nobody's problem.
_aif_work_live() {
  local f filter="$1"
  shift
  [ -n "${AIF_WORK_LOCK:-}" ] && [ -d "$AIF_WORK_LOCK" ] || return 0
  f="$AIF_WORK_LOCK/live.json"
  [ -f "$f" ] || printf '{}\n' >"$f" 2>/dev/null || return 0
  if jq "$@" "$filter" "$f" >"$f.tmp" 2>/dev/null; then
    mv "$f.tmp" "$f" 2>/dev/null || true
  else
    rm -f "$f.tmp"
  fi
  return 0
}

# _aif_work_block <root> <ticket> <kind> <why> [<body-file>] — the card goes
# to Needs Human, and its comment says why on a first line the project manager
# routes on: `blocked: ticket | run | environment | stopped — <why>`.
#
# Every way a taken card leaves the worker short of Review comes through here,
# so that a card is never in Needs Human without its reason, and never put
# back in Ready behind anyone's back, where the next run would take it again.
# The kind is the routing (/aif-pjm): the ticket's problem goes to the analyst
# as rework; a run that stopped, the machine, or a person stopping it are for
# the human. The body — the report, the gate's questions, a log's tail —
# follows the line that says what to do next.
#
# <full-at> says where the whole body can be read when a board cuts it to
# fit — the report, on its branch.
#
# rc 0 posted and moved · 1 either failed, with the command to do it by hand.
_aif_work_block() {
  local root="$1" ticket="$2" kind="$3" why="$4" body="${5:-}" full_at="${6:-}"
  local next f keep="" rc=0 said="why posted"
  case "$kind" in
    ticket) next="The ticket's problem, not the build's: the analyst (/aif-ba) reworks it from what is below, and it goes back to Ready." ;;
    run) next="The run stopped short of a build. What was accepted is committed on branch aif/$ticket; back in Ready, the run resumes where it stopped while the ticket is unchanged, and starts over when it changes." ;;
    environment) next="This machine, not the ticket: no station ran on it, nothing was spent. Fix what is named below, then move the card back to Ready." ;;
    stopped) next="What was accepted is committed on branch aif/$ticket; back in Ready, the run resumes where it stopped while the ticket is unchanged." ;;
    *) next="" ;;
  esac
  f="$(mktemp "${TMPDIR:-/tmp}/aif-blocked-XXXXXX")"
  {
    printf 'blocked: %s — %s\n' "$kind" "$why"
    [ -z "$next" ] || printf '\n%s\n' "$next"
    if [ -n "$body" ] && [ -s "$body" ]; then
      printf '\n'
      cat "$body"
    fi
  } >"$f"
  if ! (AIF_BOARD_BY="aif work" AIF_BOARD_FULL_AT="$full_at" aif_board_comment "$root" "$ticket" "$f" >/dev/null); then
    keep="$(aif_main_root "$root")/.aif/tmp/blocked-$ticket.md"
    { mkdir -p "$(dirname "$keep")" && cp "$f" "$keep"; } 2>/dev/null || keep="$f"
    aif_warn "why did not reach the card — post it when the board answers: aif board comment $ticket $keep"
    said="why NOT on the card (above)"
    rc=1
  fi
  if ! (aif_board_move "$root" "$ticket" needs_human >/dev/null); then
    aif_warn "could not move $ticket to needs_human on the board — run: aif board move $ticket needs_human"
    rc=1
  else
    _aif_work_say "board" "$ticket → needs_human — blocked: $kind, $said"
  fi
  [ "$keep" = "$f" ] || rm -f "$f"
  return "$rc"
}

# _aif_work_refuse <root> <ticket> <why> [<details-file>] — the machine cannot
# run this ticket, and its card was already taken: blocked: environment, then
# exit 3. No station has run, so nothing was spent; the details file, when
# there is one, is the comment's body, and is removed.
_aif_work_refuse() {
  _aif_work_block "$1" "$2" environment "$3" "${4:-}" || true
  AIF_WORK_SETTLED=1
  [ -z "${4:-}" ] || rm -f "$4"
  exit 3
}

# _aif_work_lock_pid <lock-dir> — the pid that holds the run lock, or empty.
_aif_work_lock_pid() {
  jq -r '.pid // empty' "$1/owner.json" 2>/dev/null
}

# _aif_work_lock_live <lock-dir> — rc 0 when a worker is behind the lock.
#
# A pid that is gone is a worker killed outright — kill -9, a closed laptop, a
# reboot — that never ran its handler; one the system has since handed to some
# other program is not a worker either. A lock with no owner written yet was
# taken a moment ago, or by a run that died between the mkdir and the write,
# and its age tells the two apart.
_aif_work_lock_live() {
  local pid cmd
  pid="$(_aif_work_lock_pid "$1")"
  if [ -z "$pid" ]; then
    [ -n "$(find "$1" -maxdepth 0 -mmin -1 2>/dev/null)" ]
    return
  fi
  kill -0 "$pid" 2>/dev/null || return 1
  # Held, then matched: `ps | grep -q` under pipefail is FINDINGS #19.
  cmd="$(ps -o command= -p "$pid" 2>/dev/null)" || return 1
  case "$cmd" in
    *aif*) return 0 ;;
  esac
  return 1
}

# _aif_work_lock <root> <ticket> — take the run lock for <ticket>, or say who
# holds it. rc 0 taken, AIF_WORK_LOCK names it · 1 held, AIF_WORK_LOCK_HELD
# says by what.
#
# Nothing else stops a second `aif work` on the same ticket: it reuses the
# worktree, resumes the same run record, and dispatches into the tree the
# first one is dispatching into. The board cannot say it either — the card
# moves a moment AFTER this, and on a shared board it says nothing about which
# machine took it.
#
# A lock whose worker is gone is taken over. Two runs that find the same dead
# lock in the same instant can both take it over: the remove and the mkdir are
# two steps, and no POSIX primitive makes them one without flock. The window
# is that instant after a crash, and it is written down rather than pretended
# away.
_aif_work_lock() {
  local root="$1" ticket="$2" lock pid
  AIF_WORK_LOCK_HELD=""
  lock="$(aif_run_lock_dir "$root" "$ticket")"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  if ! mkdir "$lock" 2>/dev/null; then
    if _aif_work_lock_live "$lock"; then
      AIF_WORK_LOCK_HELD="$(jq -r '"pid " + (.pid | tostring) + ", since " + .started_at' "$lock/owner.json" 2>/dev/null)"
      [ -n "$AIF_WORK_LOCK_HELD" ] || AIF_WORK_LOCK_HELD="its lock was taken a moment ago"
      return 1
    fi
    pid="$(_aif_work_lock_pid "$lock")"
    rm -rf "${lock:?}"
    if ! mkdir "$lock" 2>/dev/null; then
      AIF_WORK_LOCK_HELD="another run took it just now"
      return 1
    fi
    _aif_work_say "lock" "$ticket — the worker that held it (pid ${pid:-?}) is gone; taken over"
  fi
  jq -n --argjson pid "$$" --arg t "$ticket" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{ ticket: $t, pid: $pid, started_at: $at }' >"$lock/owner.json.tmp" &&
    mv "$lock/owner.json.tmp" "$lock/owner.json"
  AIF_WORK_LOCK="$lock"
  return 0
}

# _aif_work_unlock — release the run lock, if this process is the one holding it.
_aif_work_unlock() {
  local lock="${AIF_WORK_LOCK:-}"
  [ -n "$lock" ] || return 0
  AIF_WORK_LOCK=""
  [ "$(_aif_work_lock_pid "$lock")" = "$$" ] || return 0
  rm -rf "${lock:?}"
}

# _aif_work_descendants <pid> — every process below <pid>, one per line.
#
# What a terminal's Ctrl-C reaches by signalling a process group, found by
# walking the tree instead: a worker that `--loop` or a script started shares
# its group with whoever started it, and a signal to the group would stop the
# loop with it.
_aif_work_descendants() {
  ps -A -o pid= -o ppid= 2>/dev/null | awk -v root="$1" '
    { parent[$1] = $2 }
    END {
      want[root] = 1
      do {
        grew = 0
        for (p in parent) if (!(p in want) && (parent[p] in want)) { want[p] = 1; grew = 1 }
      } while (grew)
      for (p in want) if (p != root) print p
    }'
}

# _aif_work_stop <root> <ticket> — `aif work <ID> --stop`: end the run that is
# building <ticket> on this machine, from any terminal, the way its own Ctrl-C
# would — the station ended, the card in Needs Human saying who stopped it.
#
# TERM, not INT. A job a script puts in the background starts with SIGINT
# ignored, and bash can neither trap nor reset a signal it started ignoring
# (docs/FINDINGS.md #23): an INT would reach nothing in exactly the workers a
# loop or a CI script starts. And not to the worker alone: bash runs a trap
# only once the foreground command returns, so a TERM to the worker by itself
# waits out the station — the better part of an hour, at worst. Everything
# under the worker gets it too, and the handler runs at once.
#
# rc 0 stopped, or found gone and settled · 1 nothing to stop, or it did not
# stop within a minute.
_aif_work_stop() {
  local root="$1" ticket="$2" lock pid who col p t0 now last
  lock="$(aif_run_lock_dir "$root" "$ticket")"
  if [ ! -d "$lock" ]; then
    aif_err "no worker on this machine is building $ticket — nothing to stop (a run on another machine holds its lock there)"
    return 1
  fi
  who="$(git -C "$root" config user.name 2>/dev/null || true)"
  [ -n "$who" ] || who="${USER:-someone}"
  pid="$(_aif_work_lock_pid "$lock")"
  if ! _aif_work_lock_live "$lock"; then
    # The worker is gone without running its handler, and nothing but this
    # will tell its card so.
    col="$(aif_board_show_json "$root" "$ticket" 2>/dev/null | jq -r '.column // empty' 2>/dev/null)"
    rm -rf "${lock:?}"
    if [ "$col" = "in_progress" ]; then
      _aif_work_block "$root" "$ticket" stopped \
        "by $who (aif work $ticket --stop): the worker that took it (pid ${pid:-?}) was already gone, and had left the card In Progress" "" || true
      printf '%sstopped%s %s — its worker was already gone; the card is in needs_human\n' \
        "$AIF_C_GREEN" "$AIF_C_RESET" "$ticket"
    else
      printf 'no live worker on %s — removed the run lock it left (pid %s); the card is in %s, untouched\n' \
        "$ticket" "${pid:-?}" "${col:-an unknown column}"
    fi
    return 0
  fi
  if [ -z "$pid" ]; then
    aif_err "the run on $ticket took its lock a moment ago and has not signed it yet — run this again"
    return 1
  fi
  printf '%s\n' "$who" >"$lock/stop"
  _aif_work_say "stop" "$ticket — TERM to its worker (pid $pid) and to what it is running"
  kill -TERM "$pid" 2>/dev/null || true
  for p in $(_aif_work_descendants "$pid"); do
    kill -TERM "$p" 2>/dev/null || true
  done
  # A process the worker started after the tree was read escaped that round,
  # and if it is the station, the handler waits it out. So until the handler
  # says it is running, what is under the worker is signalled again — and
  # after that never: the handler's own board calls are under the worker too.
  t0="$(date +%s)"
  last="$t0"
  while kill -0 "$pid" 2>/dev/null; do
    now="$(date +%s)"
    if [ $((now - t0)) -gt 60 ]; then
      aif_err "the worker on $ticket (pid $pid) has not exited a minute after the TERM — it may still be writing the card's comment. Run this again to see where it got to"
      return 1
    fi
    if [ ! -f "$lock/ack" ] && [ $((now - last)) -ge 3 ]; then
      for p in $(_aif_work_descendants "$pid"); do
        kill -TERM "$p" 2>/dev/null || true
      done
      last="$now"
    fi
    sleep 0.1 2>/dev/null || sleep 1
  done
  col="$(aif_board_show_json "$root" "$ticket" 2>/dev/null | jq -r '.column // empty' 2>/dev/null)"
  printf '%sstopped%s %s — the card is in %s\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$ticket" "${col:-an unknown column}"
  return 0
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
  # Committed, because the branch is brought up to this checkout's set before
  # a run and lands back into it afterwards: a guide git does not track here
  # would be committed on the branch and then stand in the way of its own
  # merge. Said as what it is — for one release the worktree check read a
  # branch older than the guide as an uncommitted file (docs/DEFECTS.md 9.1).
  if ! aif_guide_committed "$root"; then
    aif_err "$AIF_GUIDE_FILE is not committed in your checkout — the stations run on a branch that is brought up to this checkout's set and lands back into it, and a file git does not track here would stand in the way of that merge. Commit it: git add $AIF_GUIDE_FILE && git commit"
    exit 3
  fi

  # A project.json behind the template it was made from: the gates read the
  # file as it is, so this is a warning and not a refusal — but said on every
  # run, because an upgraded project kept failure classes the gate no longer
  # means and nothing told it (docs/DEFECTS.md 8.1).
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
  #
  # Once per loop, not once per worker. The probe runs the whole suite HERE,
  # removing the report first and then waiting for it to appear, and N workers
  # starting together would run N suites in this checkout, each deleting the
  # report another is waiting on. The loop asks it before its first worker
  # and hands each one AIF_WORK_LOOP=1.
  if [ "${AIF_WORK_LOOP:-}" != "1" ]; then
    # shellcheck source=lib/doctor.sh
    . "$AIF_ROOT/lib/doctor.sh"
    if ! aif_doctor_probe "$root" >/dev/null 2>&1; then
      aif_doctor_probe "$root" >&2 || true
      aif_err "the test toolchain cannot produce a verdict — every gate reads that report."
      exit 3
    fi
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

# _aif_work_set_forward <root> <wt> <ticket> — the branch's copy of the set is
# brought up to the developer's checkout before anything reads it.
#
# Everything a run reads about aif, it reads from the WORKTREE: the stations'
# instructions and caps (.claude/agents), every gate (.aif/gates), the hooks
# and their registration, the runner fragments, the guide, project.json. That
# is right for a branch cut from the set in use, and `aif init` upgrades only
# the checkout it runs in — so every branch cut before an upgrade kept the old
# set: at 0.9.0 → 0.11.0 that was every ticket in Needs Human and Review, and
# the 0.11.0 driver would have dispatched 0.9.0's plan station, with 0.9.0's
# instructions and 0.9.0's cap, to be judged by 0.9.0's gate (docs/DEFECTS.md
# 9.1). `prepare` was already read from the developer's checkout for exactly
# this reason; this applies the same reasoning to the rest, the way aif init
# applies it to a project: the manifest's files are copied over, the files an
# older manifest listed and this set no longer ships are removed, and the
# result is committed on the branch, so the branch stays what CI and a
# reviewer can check against — a set, named by version, not a mixture.
#
# Said when anything moved; silent for a branch that is already current (a
# fresh worktree always is). rc 0 always.
_aif_work_set_forward() {
  local root="$1" wt="$2" ticket="$3" p from to n=0 r=0 paths old_paths manifest
  [ "$wt" != "$root" ] || return 0
  manifest="$root/.aif/manifest.json"
  [ -f "$manifest" ] || return 0
  to="$(jq -r '.set_version // "?"' "$manifest" 2>/dev/null)"
  from="$(jq -r '.set_version // "?"' "$wt/.aif/manifest.json" 2>/dev/null)" || from="?"
  [ -n "$from" ] || from="?"
  # What the set installed, and what aif writes beside it that the gates and
  # the stations read from the branch.
  paths="$(
    jq -r '.files[]?.path' "$manifest" 2>/dev/null
    printf '%s\n' .aif/manifest.json .aif/project.json .claude/settings.json "$AIF_GUIDE_FILE"
  )"
  old_paths="$(jq -r '.files[]?.path' "$wt/.aif/manifest.json" 2>/dev/null || true)"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # Per-developer state is the developer's, not the branch's.
    ! git -C "$root" check-ignore -q "$p" 2>/dev/null || continue
    if [ -f "$root/$p" ]; then
      if ! cmp -s "$root/$p" "$wt/$p" 2>/dev/null; then
        mkdir -p "$wt/$(dirname "$p")"
        cp "$root/$p" "$wt/$p"
        [ ! -x "$root/$p" ] || chmod +x "$wt/$p"
        git -C "$wt" add -A -- "$p" >/dev/null 2>&1 || true
        n=$((n + 1))
      fi
    fi
  done <<EOF
$(printf '%s\n' "$paths" | awk '!seen[$0]++')
EOF
  # Files the branch's manifest listed as the set's and this set no longer
  # ships — an old gate, a retired command — go, as aif init retires them.
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf '%s\n' "$paths" | grep -qxF -- "$p" && continue
    [ -f "$wt/$p" ] || continue
    rm -f "${wt:?}/${p:?}"
    git -C "$wt" add -A -- "$p" >/dev/null 2>&1 || true
    r=$((r + 1))
  done <<EOF
$old_paths
EOF
  [ $((n + r)) -gt 0 ] || return 0
  if ! git -C "$wt" diff --cached --quiet 2>/dev/null; then
    git -C "$wt" -c user.email="aif@local" -c user.name="aif" \
      commit -q -m "aif: set $to for $ticket — the branch brought up to the checkout's set (from $from)" >/dev/null 2>&1 || true
  fi
  _aif_work_say "set" "aif/$ticket brought up to the checkout's set ($from → $to): $n file(s) refreshed, $r retired, committed on the branch"
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
# (docs/DEFECTS.md 4.11). The preflight probe could not have seen it: it
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
# start — nothing was spent. AIF_WORK_ENV_WHY then says what failed in one
# line and AIF_WORK_ENV_MORE names a file with the rest: the card was already
# taken, and its comment carries both.
_aif_work_ready_worktree() {
  local root="$1" wt="$2" ticket="$3"
  local prepare marker log rc=0 probe_out
  AIF_WORK_ENV_WHY=""
  AIF_WORK_ENV_MORE=""

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
      AIF_WORK_ENV_WHY="prepare failed (exit $rc) in the worktree: $prepare"
      AIF_WORK_ENV_MORE="$(mktemp "${TMPDIR:-/tmp}/aif-env-XXXXXX")"
      {
        printf 'The command is "prepare" in .aif/project.json; it runs once in a fresh worktree. The end of its log, %s:\n\n' "${log#"$root"/}"
        grep -v '^[[:space:]]*$' "$log" | sed 's/\x1b\[[0-9;]*m//g' | tail -15 | cut -c1-240 | sed 's/^/    /'
      } >"$AIF_WORK_ENV_MORE" 2>/dev/null || true
      return 3
    fi
    : >"$marker"
  fi

  # Once, held: the suite is the slow part of the probe, and the run that
  # fails it used to run it a second time just to print what the first said.
  # shellcheck source=lib/doctor.sh
  . "$AIF_ROOT/lib/doctor.sh"
  if ! probe_out="$(aif_doctor_probe "$wt" 2>&1)"; then
    printf '%s\n' "$probe_out" >&2
    aif_err "the suite cannot run in ${wt#"$root"/}, where the stations run — nothing was spent."
    if [ -z "$prepare" ]; then
      aif_err "A fresh worktree holds tracked files only. If the runner needs installed"
      aif_err "dependencies, set \"prepare\" in .aif/project.json (e.g. \"npm ci\") and the"
      aif_err "worker runs it once after cutting the worktree."
    fi
    AIF_WORK_ENV_WHY="the suite cannot run in the worktree, where the stations run"
    AIF_WORK_ENV_MORE="$(mktemp "${TMPDIR:-/tmp}/aif-env-XXXXXX")"
    {
      printf '%s\n' "$probe_out" | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^/    /'
      if [ -z "$prepare" ]; then
        printf '\nA fresh worktree holds tracked files only. If the runner needs installed dependencies, set "prepare" in .aif/project.json (e.g. "npm ci"): the worker runs it once after cutting the worktree.\n'
      fi
    } >"$AIF_WORK_ENV_MORE" 2>/dev/null || true
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
# (docs/DEFECTS.md 6.3). A lockfile is the promise of what an install builds;
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
# AIF_WORK_NOT_READY holds the gate's own lines · 3 the board could not hand
# the ticket over — the machine's problem, not the ticket's.
_aif_work_intake() {
  local root="$1" wt="$2" ticket="$3"
  local work src base rc=0 out pull_err

  work="$(aif_task_dir "$wt" "$ticket")"
  src="$(aif_task_dir "$root" "$ticket")"

  # The board is canonical for the ticket's text until this moment: on a
  # trello board the card's description is pulled into THIS checkout and
  # becomes the bytes the run freezes. The local board holds no text — the
  # ticket is already in tasks/, and the copy below carries it in.
  #
  # A card the analyst did not write — no aif:meta in its description — is the
  # ticket's problem; anything else that stops the pull (the network, the
  # token) is the machine's, and the card's comment has to say which.
  if [ "$(aif_board_kind "$wt")" = "trello" ]; then
    if ! pull_err="$( (aif_board_pull "$wt" "$ticket" >/dev/null) 2>&1)"; then
      [ -z "$pull_err" ] || printf '%s\n' "$pull_err" >&2
      aif_err "could not pull $ticket from the board — nothing was built."
      AIF_WORK_NOT_READY="$(printf '%s' "$pull_err" | sed 's/\x1b\[[0-9;]*m//g')"
      case "$pull_err" in
        *aif:meta*) return 1 ;;
      esac
      return 3
    fi
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

  local set_version old_base old_status set_was put_back
  set_version="$(jq -r '.set_version // empty' "$wt/.aif/manifest.json" 2>/dev/null)"
  base="$(git -C "$wt" rev-parse HEAD 2>/dev/null || printf 'none')"
  if [ -f "$(aif_run_path "$work")" ] && aif_run_resumable "$work" "$set_version"; then
    # The ticket has not moved since the last run stopped. Keep the stage; give
    # it a fresh attempt count and a fresh budget, because this is a new
    # invocation and the caps are per-invocation. NOT a fresh base: the report
    # diffs base..HEAD to say what the ticket built, and resetting it here made
    # a resumed run — one that resumes at `done` most of all — report "no code
    # changed" about a branch holding all of it (docs/DEFECTS.md 3.13). A
    # record from before the field existed gets one now, and only then.
    # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags below
    aif_run_update "$work" \
      '.attempts = {} | .dispatches = 0 | .spent_usd = 0 | .status = "running"
       | .why = null | .finished_at = null | .started_at = $at
       | .base = (.base // $base) | .set_version = (.set_version // $sv)' \
      --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg base "$base" --arg sv "$set_version"
    # A plan station resumed is a plan station about to read the repository,
    # and a plan that stopped — on a spec stop, mostly — left its contract on
    # the floor: skeletons and edits nothing committed. Read as the repository,
    # they would become the next plan's premises (docs/DEFECTS.md 10.3). The
    # stations after it keep their uncommitted work: a retried station fixes
    # its own.
    if [ "$(aif_run_get "$work" '.stage')" = "plan" ] && [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
      put_back="$(git -C "$wt" status --porcelain 2>/dev/null | grep -vcE " (\.aif/|\.claude/|$AIF_TASKS_DIR/$ticket/)" || true)"
      _aif_work_restore_since "$wt" HEAD "^(\.aif/|\.claude/|$AIF_TASKS_DIR/$ticket/)"
      _aif_work_say "resume" "$(aif_run_get "$work" '.stage') — the ticket has not changed since the last run; ${put_back:-0} file(s) the stopped plan left are put back, the plan station reads the repository as the branch has it"
    else
      _aif_work_say "resume" "$(aif_run_get "$work" '.stage') — the ticket has not changed since the last run"
    fi
  else
    if [ -f "$(aif_run_path "$work")" ]; then
      old_base="$(aif_run_get "$work" '.base')"
      old_status="$(aif_run_get "$work" '.status')"
      set_was="$(aif_run_set_changed "$work" "$set_version")"
      # A run that did not build starts over on the tree it started from: the
      # stopped plan's skeleton, the edits it made, its committed plan and
      # tests all answer the old ticket or come from the old set, and left in
      # place they are what the new plan station would read as the
      # repository — and what the first accepted station's `git add -A` would
      # commit under the new plan's name (docs/DEFECTS.md 10.3, 9.1). The
      # ticket's record stays; the history stays; the tree goes back, in a
      # commit that says so. A run that BUILT is a rework: the new round
      # builds on the code the last one delivered, as it always did.
      if [ "$old_status" != "built" ] && [ -n "$old_base" ] && [ "$old_base" != "none" ] &&
        git -C "$wt" rev-parse -q --verify "$old_base^{commit}" >/dev/null 2>&1; then
        put_back="$({
          git -C "$wt" -c core.quotePath=false diff --name-only "$old_base" 2>/dev/null
          git -C "$wt" -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null
        } | sort -u | grep -vcE "^(\.aif/|\.claude/|$AIF_TASKS_DIR/$ticket/)" || true)"
        # Not the set, which was just brought up to the checkout's; not the
        # ticket's record; everything else the old run and its stations did.
        _aif_work_restore_since "$wt" "$old_base" "^(\.aif/|\.claude/|$AIF_TASKS_DIR/$ticket/(ledger\.json|run\.json|stations/|ticket\.md)$)"
        git -C "$wt" add -A >/dev/null 2>&1 || true
        if ! git -C "$wt" diff --cached --quiet 2>/dev/null; then
          git -C "$wt" -c user.email="aif@local" -c user.name="aif" \
            commit -q -m "aif: restart $ticket — the tree put back to ${old_base:0:7} before a new plan" >/dev/null 2>&1 || true
        fi
        base="$(git -C "$wt" rev-parse HEAD 2>/dev/null || printf 'none')"
      else
        put_back=""
      fi
      if [ -n "$set_was" ]; then
        _aif_work_say "restart" "the set moved since the last run ($set_was → ${set_version:-?}) — the plan below it was written by the old set's stations${put_back:+; ${put_back} file(s) put back to ${old_base:0:7}}"
      else
        _aif_work_say "restart" "the ticket changed since the last run — the plan below it no longer answers it${put_back:+; ${put_back} file(s) put back to ${old_base:0:7}}"
      fi
    fi
    aif_run_init "$work" "$ticket" \
      "$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '?')" \
      "$base" "${wt#"$root"/}" "$set_version"
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
# release while the design said four (docs/DEFECTS.md 8.4).
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
  # and a station cut off mid-file costs a dispatch (docs/DEFECTS.md (log 6)); the
  # cap's remaining job is a station that loops without producing.
  [ -n "$max_turns" ] || max_turns="$(jq -r '.limits.station_max_turns // 60' "$project" 2>/dev/null)"
  [ -n "$model" ] || model="sonnet"
  [ -n "$tools" ] || tools="Read,Grep,Glob,Write,Edit"
  # The alias the station asks for, and what the profile maps it to — what
  # actually answered replaces that once the envelope says (below).
  local resolved=""
  case "$model" in
    opus) resolved="${ANTHROPIC_DEFAULT_OPUS_MODEL:-}" ;;
    sonnet) resolved="${ANTHROPIC_DEFAULT_SONNET_MODEL:-}" ;;
    haiku) resolved="${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}" ;;
  esac
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  _aif_work_live '.model = $m | .model_id = ((.models // {})[$s] // (if $r == "" then null else $r end))' \
    --arg m "$model" --arg s "$station" --arg r "$resolved"

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
      "REPLAN"* | "MERGE"* | "REBUILD"*)
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
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  _aif_work_live '.tokens = ((.tokens // 0) + $o) | .models[$s] = $id | .model_id = $id' \
    --argjson o "$(printf '%s' "$usage" | jq -r '.output_tokens // 0')" --arg s "$station" --arg id "$model_ran"
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
# (docs/DEFECTS.md 3.4). A guard against a runaway run takes the larger; a
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

# _aif_work_sync <root> <wt> <ticket> <budget-left> <dispatched> — the ticket's
# branch brought onto the branch it lands on, before the run says built
# (docs/DEFECTS.md 13.4).
#
# A ticket's branch is cut from the checkout's HEAD on its first run, and with
# --loop two of them are cut from the same HEAD: whichever lands second meets
# the first in every file both touched. `aif land` used to stop there and hand
# the conflict to a human; with tickets built side by side that is the normal
# case, and nothing in it is a decision. So the last thing a run does is take
# in what the checkout's branch holds now — in the worktree, never in the
# developer's checkout:
#
#   merge   the checkout's HEAD into aif/<ID>, --no-commit; nothing to do when
#           the branch already holds it
#   own     conflicts in aif's own files settled by owner (lib/integrate.sh); a
#           conflicted lockfile taken from the target, for the package manager
#           to write again
#   tests   a conflict in a test file is the oracle's, and no merge settles a
#           frozen test: the run is built again instead (rc 1)
#   code    a conflict in code goes to the implement station, MERGE in its
#           prompt: both sides' intent to hold, no marker to stay
#   judged  the dependencies installed again when the merge moved them; the
#           test files the target brought taken into the lock; green and scope
#           on the merged tree, the run record naming the commit it was brought
#           onto. A rejection goes back to the station with the gates' words,
#           up to the implement station's attempts cap
#   sealed  one merge commit: aif: sync <ID> onto <branch> at <sha>
#
# rc 0 the branch holds the target · 1 it could not be brought on — a test file
# in conflict, or the station's attempts spent — and the ticket is to be built
# again from the target (AIF_WORK_SYNC_WHY) · 3 the environment: an install
# that failed, a gate with no verdict, a merge git would not start.
# AIF_WORK_SYNC_DISPATCHES and AIF_WORK_SYNC_SPENT are what it cost.
_aif_work_sync() {
  local root="$1" wt="$2" ticket="$3" budget_left="$4" dispatched="${5:-0}"
  local work project target target_name pre p left="" lockfiles="" tests_hit="" roots
  local agent attempts_max n=0 complaint="" out rc gate_out markers deps deps_done="" prepare log tab
  local replan_was replan_now lock_kept=""
  AIF_WORK_SYNC_WHY=""
  AIF_WORK_SYNC_DISPATCHES=0
  AIF_WORK_SYNC_SPENT=0
  AIF_INTEGRATE_SETTLED=""
  AIF_INTEGRATE_LEFT=""
  [ "$wt" != "$root" ] || return 0
  target="$(git -C "$root" rev-parse -q --verify HEAD 2>/dev/null)" || return 0
  # A checkout on no branch names nothing to land on: there is no target.
  target_name="$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null)" || return 0
  [ -n "$target_name" ] || return 0
  ! git -C "$wt" merge-base --is-ancestor "$target" HEAD 2>/dev/null || return 0
  work="$(aif_task_dir "$wt" "$ticket")"
  project="$(aif_project_config "$wt")"
  tab="$(printf '\t')"

  # What the run left uncommitted is its own record: in first, because git does
  # not start a merge over local changes to a path the merge brings.
  if [ -n "$(git -C "$wt" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    git -C "$wt" add -A "$AIF_TASKS_DIR/$ticket" >/dev/null 2>&1 || true
    git -C "$wt" -c user.email="aif@local" -c user.name="aif" \
      commit -q -m "aif: record $ticket before the sync" >/dev/null 2>&1 || true
  fi
  pre="$(git -C "$wt" rev-parse HEAD)"
  _aif_work_say "sync" "aif/$ticket onto $target_name at ${target:0:7}"

  if ! git -C "$wt" -c merge.conflictStyle=diff3 merge --no-ff --no-commit "$target" >/dev/null 2>&1; then
    if ! git -C "$wt" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
      AIF_WORK_SYNC_WHY="git would not start the merge of $target_name into aif/$ticket in ${wt#"$root"/}"
      _aif_work_sync_abort "$wt" "$pre"
      return 3
    fi
    aif_integrate_own "$wt" "$ticket" ours || true
    roots="$(jq -r '.test.roots[]?' "$project" 2>/dev/null)"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if _aif_work_is_test_path "$p" "$roots" "$work"; then
        tests_hit="$tests_hit$p
"
      elif printf '%s\n' "$p" | grep -qE "$AIF_DEP_LOCKFILES" && aif_integrate_take "$wt" "$p" theirs; then
        lockfiles="$lockfiles$p
"
      else
        left="$left$p
"
      fi
    done <<EOF
$AIF_INTEGRATE_LEFT
EOF
    if [ -n "$tests_hit" ]; then
      AIF_WORK_SYNC_WHY="it conflicts with $target_name in test files — $(printf '%s' "$tests_hit" | paste -sd ',' - | sed 's/,/, /g'): the oracle is in conflict, and no merge settles a frozen test"
      _aif_work_sync_abort "$wt" "$pre"
      return 1
    fi
  fi
  # shellcheck disable=SC2016  # jq's variable, bound by --arg
  aif_run_update "$work" '.sync_base = $t' --arg t "$target" || true
  # The test files the merge brought, taken into the lock now — from the merge
  # alone, before any station touches the tree — and the lock kept: it is the
  # worker's, and a station that rewrote it could bless an edit to a frozen
  # test. It is put back after every dispatch.
  _aif_work_lock_rebase "$wt" "$work" "$target"
  lock_kept="$wt/.aif/tmp/sync-$ticket.lock.json"
  mkdir -p "$wt/.aif/tmp"
  [ ! -f "$work/tests.lock.json" ] || cp "$work/tests.lock.json" "$lock_kept"

  agent="$(aif_station_agent "$wt" implement "$work" 2>/dev/null)"
  attempts_max="$(_aif_work_attempts_max "$wt" implement "$project")"
  gate_out="$wt/.aif/tmp/sync-$ticket.out"
  # A replan the station writes in its note during the sync says the two sides
  # cannot hold together: the ticket is built again from the target. Told from
  # one the note already carried by what it says.
  replan_was="$(jq -r '.replan // empty' "$work/implement.note.json" 2>/dev/null)" || replan_was=""
  prepare="$(jq -r '.prepare // empty' "$(aif_project_config "$root")" 2>/dev/null)"
  if [ -n "$left" ]; then
    complaint="MERGE — this ticket's branch is being brought onto $target_name, which moved since the branch was cut: $target_name's commits since then are merged into the tree, and these files hold conflicts git could not settle, marked in diff3 style (<<<<<<< this ticket, ||||||| the common base, ======= then $target_name, >>>>>>>):
$(printf '%s' "$left" | sed '/^$/d; s/^/  - /')
Settle each so that both hold — what this ticket's plan built and what $target_name changed: read both sides, keep the behaviour of each. Leave no conflict marker. Change only what the merge needs, in the files above and the plan's own; never a test file, never anything under $AIF_TASKS_DIR/. $target_name's commits since the branch was cut, newest first:
$(git -C "$wt" log --format='  %h %s' "$pre..$target" 2>/dev/null | sed -n '1,20p')
The gates judge the merged tree when you finish: this ticket's frozen tests, every test $target_name has, and the project's checks."
  fi

  while :; do
    if [ -n "$complaint" ]; then
      n=$((n + 1))
      if [ "$n" -gt "$attempts_max" ]; then
        AIF_WORK_SYNC_WHY="the implement station could not bring aif/$ticket onto $target_name in $attempts_max attempt(s); the last word on it: $(printf '%s\n' "$complaint" | grep -v '^[[:space:]]*$' | sed -n 2p | cut -c1-200)"
        _aif_work_sync_abort "$wt" "$pre"
        return 1
      fi
      _aif_work_say "sync" "the implement station, MERGE (attempt $n/$attempts_max)"
      out="$(mktemp "${TMPDIR:-/tmp}/aif-env-XXXXXX")"
      rc=0
      _aif_work_dispatch "$wt" "$ticket" implement "$agent" "$complaint" "$budget_left" "$out" || rc=$?
      if [ "$rc" -eq 3 ]; then
        rm -f "$out"
        AIF_WORK_SYNC_WHY="the runner could not run the implement station for the sync (no envelope) — the environment, not the ticket"
        _aif_work_sync_abort "$wt" "$pre"
        return 3
      fi
      AIF_WORK_SYNC_DISPATCHES=$((AIF_WORK_SYNC_DISPATCHES + 1))
      _aif_work_keep_envelope "$wt" "$ticket" "$((dispatched + AIF_WORK_SYNC_DISPATCHES))" implement "$out"
      AIF_WORK_SYNC_SPENT="$(awk -v s="$AIF_WORK_SYNC_SPENT" -v c="$(_aif_work_envelope_cost "$wt" "$out")" 'BEGIN { printf "%.4f", s + c }')"
      rm -f "$out"
      if [ -f "$lock_kept" ] && ! cmp -s "$lock_kept" "$work/tests.lock.json"; then
        cp "$lock_kept" "$work/tests.lock.json"
        _aif_work_say "sync" "the station changed tests.lock.json — put back; the lock is the worker's"
      fi
      replan_now="$(jq -r '.replan // empty' "$work/implement.note.json" 2>/dev/null)" || replan_now=""
      if [ -n "$replan_now" ] && [ "$replan_now" != "$replan_was" ]; then
        AIF_WORK_SYNC_WHY="the implement station declares that this ticket and $target_name cannot hold together as built: $(printf '%s' "$replan_now" | sed -n 1p | cut -c1-200)"
        _aif_work_sync_abort "$wt" "$pre"
        return 1
      fi
      markers=""
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        if grep -qE '^(<<<<<<<|\|\|\|\|\|\|\||=======|>>>>>>>)( |$)' "$wt/$p" 2>/dev/null; then
          markers="$markers$p
"
        fi
      done <<EOF
$left
EOF
      if [ -n "$markers" ]; then
        complaint="MERGE, again — conflict markers are still in:
$(printf '%s' "$markers" | sed '/^$/d; s/^/  - /')
Settle each conflict: both sides' behaviour kept, and no <<<<<<<, |||||||, ======= or >>>>>>> line left."
        continue
      fi
      git -C "$wt" add -A >/dev/null 2>&1 || true
    fi

    # The dependencies, whenever the tree's manifests or lockfiles are no
    # longer what was installed: what the merge brought, or what the station
    # wrote. Installed from the lockfile, as everywhere else (6.3).
    deps="$(git -C "$wt" -c core.quotePath=false diff --name-only "$pre" 2>/dev/null | grep -E "$AIF_DEP_MANIFESTS|$AIF_DEP_LOCKFILES" | sort -u)" || deps=""
    if [ -n "$prepare" ] && [ -n "$deps" ] && [ "$deps" != "$deps_done" ]; then
      _aif_work_say "prepare" "$(printf '%s' "$deps" | paste -sd ' ' -) moved in the sync — $prepare"
      mkdir -p "$wt/.aif/tmp"
      log="$wt/.aif/tmp/prepare.log"
      rc=0
      (cd "$wt" && eval "$prepare") </dev/null >"$log" 2>&1 || rc=$?
      if [ "$rc" -ne 0 ]; then
        complaint="MERGE, again — the dependencies of the merged tree do not install: \"prepare\" ($prepare) exits $rc:
$(grep -v '^[[:space:]]*$' "$log" | sed 's/\x1b\[[0-9;]*m//g' | tail -12 | cut -c1-240 | sed 's/^/    /')
A conflicted lockfile was taken from $target_name; the manifest is the merge's. Write the lockfile again through the package manager (npm install, never by hand), so that it pins what the manifest asks for."
        deps_done=""
        continue
      fi
      deps_done="$deps"
    fi

    rc=0
    "$AIF_ROOT/bin/aif" _gate implement "$ticket" >"$gate_out" 2>&1 || rc=$?
    case "$rc" in
      0) break ;;
      3)
        AIF_WORK_SYNC_WHY="a gate could not render a verdict on the merged tree:
$(sed 's/\x1b\[[0-9;]*m//g' "$gate_out" | sed -n '1,20p')"
        rm -f "$gate_out"
        _aif_work_sync_abort "$wt" "$pre"
        return 3
        ;;
      *)
        complaint="MERGE, again — the merged tree was rejected. The tree holds this ticket's work and $target_name's; make both hold. The gates' words, verbatim:
$(grep -v '^$' "$gate_out" | sed 's/\x1b\[[0-9;]*m//g' | sed -n '1,40p')"
        ;;
    esac
  done
  rm -f "$gate_out" "$lock_kept"

  git -C "$wt" add -A >/dev/null 2>&1 || true
  if ! git -C "$wt" -c user.email="aif@local" -c user.name="aif" commit -q --cleanup=strip \
    -m "aif: sync $ticket onto $target_name at ${target:0:7}" \
    -m "$(_aif_work_sync_body "$left" "$lockfiles" "$n")" >/dev/null 2>&1; then
    AIF_WORK_SYNC_WHY="could not commit the merge of $target_name into aif/$ticket"
    _aif_work_sync_abort "$wt" "$pre"
    return 3
  fi
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags below
  aif_run_update "$work" \
    '.syncs = ((.syncs // 0) + 1)
     | .sync = { onto: $t, name: $name, pre: $pre, post: $post, at: $at,
                 settled: ($settled | split("\n") | map(select(length > 0)
                   | split("\t") | { path: .[0], owner: .[1] })),
                 station: ($left | split("\n") | map(select(length > 0))),
                 attempts: ($n | tonumber),
                 lockfiles: ($locks | split("\n") | map(select(length > 0))) }' \
    --arg t "$target" --arg name "$target_name" --arg pre "$pre" \
    --arg post "$(git -C "$wt" rev-parse HEAD)" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg settled "$AIF_INTEGRATE_SETTLED" --arg left "$left" --arg n "$n" --arg locks "$lockfiles" || true
  if [ -n "$left" ]; then
    _aif_work_say "sync" "onto $target_name — $(printf '%s' "$left" | grep -c .) conflict(s) settled by the implement station in $n attempt(s); the review sees them"
  else
    _aif_work_say "sync" "onto $target_name — merged clean, judged again on the result"
  fi
  return 0
}

# _aif_work_sync_body <left> <lockfiles> <attempts> — what the sync commit
# says it did, beyond its subject.
_aif_work_sync_body() {
  local tab
  tab="$(printf '\t')"
  [ -z "$AIF_INTEGRATE_SETTLED" ] ||
    printf 'Settled by owner (aif'"'"'s own files): %s\n' \
      "$(printf '%s' "$AIF_INTEGRATE_SETTLED" | sed '/^$/d' | sed "s/$tab.*//" | paste -sd ',' - | sed 's/,/, /g')"
  [ -z "$1" ] ||
    printf 'Settled by the implement station, in %s attempt(s): %s\n' "$3" "$(printf '%s' "$1" | sed '/^$/d' | paste -sd ',' - | sed 's/,/, /g')"
  [ -z "$2" ] ||
    printf 'Taken from the target and installed again: %s\n' "$(printf '%s' "$2" | sed '/^$/d' | paste -sd ',' - | sed 's/,/, /g')"
  [ -n "$AIF_INTEGRATE_SETTLED$1$2" ] || printf 'Merged clean.\n'
}

# _aif_work_sync_abort <wt> <pre> — a sync given up: the worktree exactly as it
# was before it, the merge and whatever the station wrote gone with it.
_aif_work_sync_abort() {
  git -C "$1" merge --abort >/dev/null 2>&1 || true
  git -C "$1" reset -q --hard "$2" >/dev/null 2>&1 || true
  git -C "$1" clean -fdq >/dev/null 2>&1 || true
}

# _aif_work_is_test_path <path> <roots> <work> — rc 0 when <path> is a test
# file: under one of the project's test roots, or one this ticket's lock holds.
_aif_work_is_test_path() {
  local p="$1" r
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$p" in
      "$r"/*) return 0 ;;
    esac
  done <<EOF
$2
EOF
  [ -f "$3/tests.lock.json" ] &&
    jq -e --arg p "$p" '(.tests // {}) | has($p)' "$3/tests.lock.json" >/dev/null 2>&1
}

# _aif_work_lock_rebase <wt> <work> <onto> — the test files a sync brought,
# taken into the lock (docs/DEFECTS.md 13.4).
#
# green holds every file under the test roots to the hash it was frozen at, so
# a test the target added or changed reads as the oracle moving; it did not —
# it is the target's. Every path the lock holds or the roots now hold is
# hashed again; a changed one, a new one and a removed one are listed in
# synced_files, which green reads as pre-existing tests. A conflict in a test
# file never gets here: that ticket is built again instead.
_aif_work_lock_rebase() {
  local wt="$1" work="$2" onto="$3" lock="$2/tests.lock.json" roots rows="" synced="" p was now tmp
  [ -f "$lock" ] || return 0
  roots="$(jq -r '.test.roots[]?' "$(aif_project_config "$wt")" 2>/dev/null)"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    was="$(jq -r --arg p "$p" '.tests[$p] // ""' "$lock" 2>/dev/null)"
    now=""
    [ ! -f "$wt/$p" ] || now="$(aif_sha256 "$wt/$p")"
    [ -z "$now" ] || rows="$rows$p	$now
"
    [ "$was" = "$now" ] || synced="$synced$p
"
  done <<EOF
$({
    jq -r '.tests // {} | keys[]' "$lock" 2>/dev/null
    while IFS= read -r p; do
      [ -n "$p" ] && [ -d "$wt/$p" ] || continue
      (cd "$wt" && find "$p" -type f 2>/dev/null)
    done <<ROOTS
$roots
ROOTS
  } | sort -u)
EOF
  [ -n "$synced" ] || return 0
  tmp="$(aif_tmpfile "$lock")" || return 0
  # shellcheck disable=SC2016  # jq's variables, bound by the flags below
  if ! jq --rawfile rows <(printf '%s' "$rows") --rawfile synced <(printf '%s' "$synced") --arg onto "$onto" '
      .tests = ($rows | split("\n") | map(select(length > 0) | split("\t") | { (.[0]): .[1] }) | add // {})
      | .synced_files = (((.synced_files // []) + ($synced | split("\n") | map(select(length > 0)))) | unique)
      | .synced_onto = $onto' "$lock" >"$tmp" || ! mv "$tmp" "$lock"; then
    rm -f "$tmp"
  fi
}

# _aif_work_rebuild <root> <wt> <ticket> <why> — the build could not be brought
# onto the branch it lands on, so the ticket is built again from that branch's
# HEAD (docs/DEFECTS.md 13.4; the user's call, 2026-10-05: automatically).
#
# The build is kept, not lost: refs/aif/archive/<ID>/<n> holds it, a ref no
# branch list shows and no push sends. The worktree goes to the target, the
# ticket the run froze comes back into it, the set is brought forward and the
# dependencies installed, and a fresh run record — naming the build it
# replaces — starts at the plan station, which is told what happened and
# handed the old plan as a reference. Once per ticket (limits.rebuilds_max,
# 1): a ticket the target keeps moving under is a question for a human.
#
# rc 0 the run starts again at plan, AIF_WORK_REBUILD_COMPLAINT for the plan
# station · 1 not — the cap — and AIF_WORK_REBUILD_WHY says why · 3 the
# environment: the install failed on the target's tree.
_aif_work_rebuild() {
  local root="$1" wt="$2" ticket="$3" why="$4" work project n max old target target_name ref keep prepare log rc=0 set_version old_plan
  AIF_WORK_REBUILD_WHY=""
  AIF_WORK_REBUILD_COMPLAINT=""
  work="$(aif_task_dir "$wt" "$ticket")"
  project="$(aif_project_config "$wt")"
  n="$(aif_run_get "$work" '.rebuilds')" || n=""
  n="${n:-0}"
  max="$(jq -r '.limits.rebuilds_max // 1' "$project" 2>/dev/null)"
  if [ "$n" -ge "${max:-1}" ]; then
    AIF_WORK_REBUILD_WHY="$why — and it was built again from the branch it lands on $n time(s) already (limits.rebuilds_max). The target keeps moving under this ticket: a question for a human."
    return 1
  fi
  target="$(git -C "$root" rev-parse -q --verify HEAD 2>/dev/null)" || return 1
  target_name="$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null)" || target_name="${target:0:7}"
  ref="refs/aif/archive/$ticket/$((n + 1))"
  # The stations' own accounts of the build, kept with it: they wait under
  # .aif/tmp/ until the report, and the build they describe is about to go.
  if [ -d "$wt/.aif/tmp/stations-$ticket" ]; then
    mkdir -p "$work/stations"
    cp "$wt/.aif/tmp/stations-$ticket"/*.json "$work/stations/" 2>/dev/null || true
    rm -rf "${wt:?}/.aif/tmp/stations-${ticket:?}"
  fi
  git -C "$wt" add -A "$AIF_TASKS_DIR/$ticket" >/dev/null 2>&1 || true
  if ! git -C "$wt" diff --cached --quiet 2>/dev/null; then
    git -C "$wt" -c user.email="aif@local" -c user.name="aif" \
      commit -q -m "aif: record $ticket — the build kept at $ref" >/dev/null 2>&1 || true
  fi
  old="$(git -C "$wt" rev-parse HEAD)"
  if ! git -C "$root" update-ref "$ref" "$old" >/dev/null 2>&1; then
    AIF_WORK_REBUILD_WHY="$why — and the build could not be kept at $ref, so it was not built again"
    return 1
  fi
  old_plan="$(git -C "$wt" show "$old:$AIF_TASKS_DIR/$ticket/plan.md" 2>/dev/null | sed -n '1,150p')" || old_plan=""
  keep="$(mktemp "${TMPDIR:-/tmp}/aif-ticket-XXXXXX")"
  cp "$work/ticket.md" "$keep" 2>/dev/null || true
  git -C "$wt" reset -q --hard "$target" >/dev/null 2>&1 || {
    rm -f "$keep"
    AIF_WORK_REBUILD_WHY="$why — and the worktree could not be put at $target_name to build it again"
    return 1
  }
  git -C "$wt" clean -fdq >/dev/null 2>&1 || true
  mkdir -p "$work"
  cp "$keep" "$work/ticket.md" 2>/dev/null || true
  rm -f "$keep"
  _aif_work_set_forward "$root" "$wt" "$ticket"
  prepare="$(jq -r '.prepare // empty' "$(aif_project_config "$root")" 2>/dev/null)"
  if [ -n "$prepare" ]; then
    _aif_work_say "prepare" "$prepare — the dependencies of $target_name"
    mkdir -p "$wt/.aif/tmp"
    log="$wt/.aif/tmp/prepare.log"
    (cd "$wt" && eval "$prepare") </dev/null >"$log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      AIF_WORK_REBUILD_WHY="the ticket was to be built again from $target_name, and \"prepare\" ($prepare) failed there (exit $rc) — the environment; the build is kept at $ref"
      return 3
    fi
  fi
  set_version="$(jq -r '.set_version // empty' "$wt/.aif/manifest.json" 2>/dev/null)"
  aif_run_init "$work" "$ticket" "aif/$ticket" "$target" "${wt#"$root"/}" "$set_version"
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  aif_run_update "$work" '.rebuilds = ($n | tonumber) | .rebuilt_from = $old | .rebuild_ref = $ref | .rebuild_why = $why' \
    --arg n "$((n + 1))" --arg old "$old" --arg ref "$ref" --arg why "$why" || true
  git -C "$wt" add -A "$AIF_TASKS_DIR/$ticket" >/dev/null 2>&1 || true
  git -C "$wt" -c user.email="aif@local" -c user.name="aif" \
    commit -q -m "aif: rebuild $ticket on $target_name at ${target:0:7} — the build at ${old:0:7} could not be brought onto it; kept at $ref" >/dev/null 2>&1 || true
  _aif_work_say "rebuild" "$ticket from $target_name at ${target:0:7}; the build at ${old:0:7} is kept at $ref"
  AIF_WORK_REBUILD_COMPLAINT="REBUILD — this ticket was built before, on an older $target_name, and that build could not be brought onto $target_name as it is now: $why
It is built again from $target_name's HEAD. Plan it on the tree as it is now — the repository has moved, and the old plan's premises may not hold. The old plan, as a reference and not a constraint:
$old_plan"
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

  # Against what the branch was last brought onto, when it was: after a sync
  # the run's own base is behind the target, and base..HEAD would count every
  # change the target made as this ticket's.
  base="$(jq -r '.sync.onto // .base // "none"' "$run" 2>/dev/null)"
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

    # Where the branch was brought onto the one it lands on, and what that
    # took (docs/DEFECTS.md 13.4). A conflict settled by a station is code the
    # reviewer has not seen in any other form, so it says where to look.
    jq -r '
      (if .rebuilds then
        "\n## Built again\n\n- the build at `" + (.rebuilt_from[0:7]) + "` could not be brought onto the branch it lands on: "
        + (.rebuild_why | split("\n")[0]) + "\n- it is kept at `" + .rebuild_ref + "`; this build started from `" + (.base[0:7]) + "`"
      else empty end),
      (if .sync then
        "\n## Brought onto " + .sync.name + "\n\n- `" + .sync.name + "` at `" + (.sync.onto[0:7]) + "` merged into the branch"
        + (if (.sync.station | length) == 0 and (.sync.settled | length) == 0 and (.sync.lockfiles | length) == 0 then ", clean" else "" end)
        + (if (.sync.settled | length) > 0 then "\n- conflicts in aif'"'"'s own files, settled by owner: " + (.sync.settled | map(.path) | join(", ")) else "" end)
        + (if (.sync.lockfiles | length) > 0 then "\n- lockfiles taken from " + .sync.name + " and installed again: " + (.sync.lockfiles | join(", ")) else "" end)
        + (if (.sync.station | length) > 0 then
            "\n- **conflicts in code, settled by the implement station** in " + (.sync.attempts | tostring) + " attempt(s): "
            + (.sync.station | join(", ")) + " — look at them: `git diff " + (.sync.pre[0:7]) + " " + (.sync.post[0:7]) + " -- "
            + (.sync.station | join(" ")) + "`"
          else "" end)
        + "\n- the merged tree judged again: green and scope passed on it"
      else empty end)' "$run" 2>/dev/null

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
#                <use_worktree> <parallel> <tui> — drain Ready, <parallel> runs at
#                a time; <tui> is auto or off.
#
# The supervisor of `aif work --loop`. Each card is one `aif work <card>`, a
# child process with its own traps, caps, run lock and exit code — the
# single-ticket path above is never re-entered with half its globals set —
# and up to <parallel> of them run at once, each in its own worktree on its
# own branch (docs/REBUILD-3.md §3: N workers = N worktrees). The board is
# read again whenever a worker can start, so a card the project manager moves
# while the loop runs is taken (or not) in the order the board has then —
# queue policy stays theirs.
#
# What running several at once takes (docs/FINDINGS.md #23, #24):
#
#   taking    the loop remembers what it has taken, and skips a card whose run
#             lock is live — a worker in another terminal. A worker claims its
#             card a moment after it starts; until then the card is still at
#             the top of Ready.
#   starting  one worker at a time: the next starts once the last one's
#             worktree is ready (its run lock says intake or later) or it has
#             ended. Installs and suite probes do not run side by side, and a
#             machine that cannot run the suite costs one card in Needs Human,
#             not N.
#   preflight once, before the first worker. Its suite probe runs in this
#             checkout, removing the report and waiting for it to appear; N at
#             once would delete each other's. Each worker gets AIF_WORK_LOOP=1
#             and skips only that.
#   output    each worker writes its own log under .aif/tmp/loop-<when>/. On a
#             terminal the loop draws its dashboard (lib/tui.sh) from what each
#             worker writes into its run lock as it moves; anywhere else it
#             says one line per start and per end. A summary either way.
#   Ctrl-C    each worker starts in a process group of its own, so the
#             terminal's Ctrl-C reaches the loop alone. The first takes no new
#             card and lets the runs in flight finish; the second stops them,
#             each settling its card as stopped by Ctrl-C. `set -m` is on only
#             around the spawn: left on, bash hands the terminal to every
#             foreground command it runs — a jq, a curl, the tick's sleep — and
#             a Ctrl-C then reaches that command and not the loop.
#
# Takes no new card when Ready has none it has not taken, at --max-tickets,
# when a worker could not start (exit 3: the environment, not the card),
# after two that did not build with none built between them, or on Ctrl-C;
# then waits for the runs in flight and says how each ended. A run stopped on
# its own — `aif work <ID> --stop`, or [s] on the dashboard — is not a
# verdict on the cards: it does not count toward two in a row, and its slot
# takes the next card.
#
# Exit: 0 every ticket taken was built · 1 some were not · 3 stopped on the
# environment · 130 / 143 stopped by Ctrl-C or a TERM.
# The dashboard's state: read by lib/tui.sh, which a linter reading this file cannot see.
# shellcheck disable=SC2034
_aif_work_loop() {
  local root="$1" max="$2" profile="$3" budget="$4" budget_off="$5"
  local max_minutes="$6" use_worktree="$7" parallel="${8:-1}" tui="${9:-auto}"
  local main logdir why="" env=0 taken_n=0 in_a_row=0 next_poll=0 kill_by=0
  local now n list pick id pid rc entry left what kind mins results="" slot st i

  set --
  [ -z "$profile" ] || set -- "$@" --profile "$profile"
  if [ "$budget_off" -eq 1 ]; then
    set -- "$@" --no-budget
  elif [ -n "$budget" ]; then
    set -- "$@" --budget "$budget"
  fi
  [ -z "$max_minutes" ] || set -- "$@" --max-minutes "$max_minutes"
  [ "$use_worktree" -eq 1 ] || set -- "$@" --no-worktree

  main="$(aif_main_root "$root")"
  logdir="$main/.aif/tmp/loop-$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$logdir"

  # What the loop, its handler and its dashboard share, in globals: a trap
  # fires with the signal's name only, and lib/tui.sh draws from these.
  AIF_WORK_LOOP_ROOT="$root"
  AIF_WORK_LOOP_MAIN="$main"
  AIF_WORK_LOOP_LOGDIR="$logdir"
  AIF_WORK_LOOP_TAKEN=" "   # every card taken, space-delimited
  AIF_WORK_LOOP_STOP=""     # why no new card is taken — the first reason wins
  AIF_WORK_LOOP_CTRL_C=0    # how many Ctrl-Cs (or q) have arrived
  AIF_WORK_LOOP_KILLED=""   # INT or TERM, once every run in flight was told to stop
  AIF_WORK_LOOP_RUNNING=""  # "<pid>:<ticket>:<started>:<slot>" per run in flight
  AIF_TUI_PARALLEL="$parallel" AIF_TUI_STARTED="$(date +%s)" AIF_TUI_NOW="$AIF_TUI_STARTED"
  AIF_TUI_BUILT=0 AIF_TUI_BLOCKED=0 AIF_TUI_STOPPED=0 AIF_TUI_READY="" AIF_TUI_LOAD="" AIF_TUI_DISK=""
  AIF_TUI_EVENTS="" AIF_TUI_SEL=1 AIF_TUI_BOTTOM=events AIF_TUI_LOG="" AIF_TUI_ASK=""
  for i in $(seq 1 "$parallel"); do
    AIF_LS_PID[i]="" AIF_LS_ID[i]="" AIF_LS_RESULT[i]="" AIF_LS_KIND[i]="" AIF_LS_LIVE[i]=""
    AIF_LS_START[i]="" AIF_LS_END[i]="" AIF_LS_PCT[i]=0 AIF_LS_PSTAGE[i]=0
  done
  _aif_work_loop_tui_start "$tui"
  aif_trap_arm "_aif_work_loop_signal"

  [ "$AIF_WORK_LOOP_TUI" = 1 ] ||
    printf '\n%sloop%s %s at a time · logs in %s\n' "$AIF_C_BOLD" "$AIF_C_RESET" "$parallel" "${logdir#"$main"/}" >&2

  while :; do
    # Every run that has ended: how, and what it means for the loop.
    left=""
    for entry in $AIF_WORK_LOOP_RUNNING; do
      IFS=: read -r pid id st slot <<EOF
$entry
EOF
      if kill -0 "$pid" 2>/dev/null; then
        left="$left $entry"
        continue
      fi
      rc=0
      wait "$pid" 2>/dev/null || rc=$?
      now="$(date +%s)"
      mins=$(((now - st) / 60))
      AIF_LS_PID[slot]=""
      AIF_LS_END[slot]="$now"
      kind=""
      case "$rc" in
        0)
          AIF_TUI_BUILT=$((AIF_TUI_BUILT + 1))
          in_a_row=0
          what="built → Review"
          AIF_LS_RESULT[slot]=built
          _aif_work_loop_event green "$id built → Review · $mins min"
          ;;
        3)
          env=1
          what="could not start (exit 3)"
          AIF_LS_RESULT[slot]="env"
          [ -n "$AIF_WORK_LOOP_STOP" ] ||
            AIF_WORK_LOOP_STOP="$id could not start (exit 3) — the environment, not the card; the loop takes no new card"
          _aif_work_loop_event red "$id could not start (exit 3) — the environment, not the card; its log says what"
          ;;
        130 | 143)
          what="stopped (exit $rc)"
          AIF_TUI_STOPPED=$((AIF_TUI_STOPPED + 1))
          AIF_LS_RESULT[slot]=stopped
          if [ -z "$AIF_WORK_LOOP_KILLED" ] && [ "$AIF_WORK_LOOP_CTRL_C" -eq 0 ]; then
            _aif_work_loop_event dim "$id was stopped (exit $rc) — not counted against the cards; the loop goes on"
          else
            _aif_work_loop_event dim "$id stopped (exit $rc)"
          fi
          ;;
        *)
          kind="$(sed -n 's/.*→ needs_human — blocked: \([a-z]*\).*/\1/p' "$logdir/$id.log" 2>/dev/null | tail -1)" || kind=""
          what="not built → Needs Human${kind:+, blocked: $kind}"
          AIF_TUI_BLOCKED=$((AIF_TUI_BLOCKED + 1))
          AIF_LS_RESULT[slot]=blocked
          _aif_work_loop_event red "$id not built → Needs Human${kind:+ (blocked: $kind)} · $mins min"
          in_a_row=$((in_a_row + 1))
          if [ "$in_a_row" -ge 2 ] && [ -z "$AIF_WORK_LOOP_STOP" ]; then
            AIF_WORK_LOOP_STOP="two runs in a row did not build ($id the last) — read the cards in Needs Human before spending on a third"
          fi
          ;;
      esac
      AIF_LS_KIND[slot]="$kind"
      results="$results$id|$what|$mins
"
      next_poll=0
    done
    AIF_WORK_LOOP_RUNNING="${left# }"
    n=0
    for entry in $AIF_WORK_LOOP_RUNNING; do
      n=$((n + 1))
    done

    if [ -n "$AIF_WORK_LOOP_KILLED" ]; then
      # Every run in flight was told to stop: wait for them — each settles its
      # card first — a minute at most.
      [ "$n" -gt 0 ] || break
      [ "$kill_by" -ne 0 ] || kill_by=$(($(date +%s) + 60))
      if [ "$(date +%s)" -gt "$kill_by" ]; then
        aif_warn "still running a minute after the stop: $AIF_WORK_LOOP_RUNNING — each settles its own card when it ends"
        break
      fi
    elif [ -n "$AIF_WORK_LOOP_STOP" ]; then
      [ "$n" -gt 0 ] || break
    elif [ "$max" -gt 0 ] && [ "$taken_n" -ge "$max" ]; then
      if [ "$n" -eq 0 ]; then
        why="--max-tickets $max reached"
        break
      fi
    elif [ "$n" -lt "$parallel" ] && ! _aif_work_loop_starting "$root"; then
      now="$(date +%s)"
      if [ "$now" -ge "$next_poll" ]; then
        pick=""
        if list="$(aif_board_ready_list "$root" 2>/dev/null)"; then
          for id in $list; do
            case "$AIF_WORK_LOOP_TAKEN" in
              *" $id "*) continue ;;
            esac
            # A worker in another terminal holds it: never this loop's.
            if _aif_work_lock_live "$(aif_run_lock_dir "$root" "$id")"; then
              AIF_WORK_LOOP_TAKEN="$AIF_WORK_LOOP_TAKEN$id "
              continue
            fi
            pick="$id"
            break
          done
        elif [ "$n" -eq 0 ]; then
          why="the board's Ready column could not be read — aif board check says why"
          env=1
          break
        fi
        if [ -n "$pick" ]; then
          AIF_WORK_LOOP_TAKEN="$AIF_WORK_LOOP_TAKEN$pick "
          taken_n=$((taken_n + 1))
          slot=1
          while [ -n "${AIF_LS_PID[slot]}" ]; do
            slot=$((slot + 1))
          done
          if [ "$AIF_WORK_LOOP_TUI" = 1 ]; then
            _aif_work_loop_event orange "$pick taken · worker $slot"
          else
            printf '\n%sloop%s %s — %s · %s of %s running · %s\n' "$AIF_C_BOLD" "$AIF_C_RESET" \
              "$taken_n" "$pick" "$((n + 1))" "$parallel" "${logdir#"$main"/}/$pick.log" >&2
          fi
          # A process group of its own, so the terminal's Ctrl-C passes it by
          # — and job control off again at once, or the next foreground
          # command takes the terminal and the next Ctrl-C with it.
          set -m
          AIF_WORK_LOOP=1 "$AIF_ROOT/bin/aif" work "$pick" ${1+"$@"} </dev/null >"$logdir/$pick.log" 2>&1 &
          pid=$!
          set +m
          AIF_WORK_LOOP_RUNNING="${AIF_WORK_LOOP_RUNNING:+$AIF_WORK_LOOP_RUNNING }$pid:$pick:$(date +%s):$slot"
          AIF_LS_PID[slot]="$pid" AIF_LS_ID[slot]="$pick" AIF_LS_RESULT[slot]=running AIF_LS_KIND[slot]=""
          AIF_LS_LIVE[slot]="" AIF_LS_START[slot]="$(date +%s)" AIF_LS_END[slot]="" AIF_LS_PCT[slot]=0 AIF_LS_PSTAGE[slot]=0
          continue
        fi
        if [ "$n" -eq 0 ]; then
          why="Ready is empty"
          break
        fi
        # Nothing to take while others run: look again in a while, not every
        # second — on a Trello board every look is a request.
        next_poll=$((now + 30))
      fi
    fi
    _aif_work_loop_tick
  done
  aif_trap_disarm
  _aif_work_loop_tui_stop

  [ -z "$AIF_WORK_LOOP_STOP" ] || why="$AIF_WORK_LOOP_STOP"
  printf '\n%sloop%s %s taken, %s built — %s\n' "$AIF_C_BOLD" "$AIF_C_RESET" "$taken_n" "$AIF_TUI_BUILT" "$why" >&2
  while IFS='|' read -r id what mins; do
    [ -n "$id" ] || continue
    case "$what" in
      built*) printf '  %s · %s min · %s · aif land %s\n' "$id" "$mins" "$what" "$id" >&2 ;;
      *) printf '  %s · %s min · %s\n' "$id" "$mins" "$what" >&2 ;;
    esac
  done <<EOF
$results
EOF
  [ "$taken_n" -eq 0 ] || printf '  %slogs: %s/%s\n' "$AIF_C_DIM" "${logdir#"$main"/}" "$AIF_C_RESET" >&2

  [ "$AIF_WORK_LOOP_KILLED" != "TERM" ] || exit 143
  [ "$AIF_WORK_LOOP_CTRL_C" -eq 0 ] || exit 130
  [ "$env" -eq 0 ] || exit 3
  [ "$taken_n" -eq "$AIF_TUI_BUILT" ] || exit 1
  exit 0
}

# _aif_work_loop_starting <root> — rc 0 while a run the loop started has not
# got its worktree ready yet: until its run lock, signed by that very worker,
# says intake or later. The next worker waits for it.
_aif_work_loop_starting() {
  local root="$1" entry pid id lock
  for entry in $AIF_WORK_LOOP_RUNNING; do
    pid="${entry%%:*}"
    id="${entry#*:}"
    id="${id%%:*}"
    lock="$(aif_run_lock_dir "$root" "$id")"
    [ "$(_aif_work_lock_pid "$lock")" = "$pid" ] || return 0
    case "$(cat "$lock/phase" 2>/dev/null)" in
      intake | run | report) ;;
      *) return 0 ;;
    esac
  done
  return 1
}

# _aif_work_loop_event <tone> <text> — one thing that happened: into the loop's
# own log, and onto the dashboard, newest first — or, with no dashboard, said.
_aif_work_loop_event() {
  local at
  at="$(date '+%H:%M')"
  printf '%s %s\n' "$at" "$2" >>"$AIF_WORK_LOOP_LOGDIR/loop.log" 2>/dev/null || true
  if [ "${AIF_WORK_LOOP_TUI:-0}" = 1 ]; then
    AIF_TUI_EVENTS="$(printf '%s|%s|%s\n%s\n' "$1" "$at" "$2" "$AIF_TUI_EVENTS" | sed -n '1,3p')"
  else
    _aif_work_say "loop" "$2"
  fi
}

# _aif_work_loop_tui_start <auto|off> — the dashboard, when this is a terminal
# a person is looking at: stderr a tty, a controlling terminal to read keys
# from, a TERM that can draw. Colour unless NO_COLOR; orange from 256 colours,
# else yellow; box drawing where the locale is UTF-8, ASCII where it is not —
# and a UTF-8 locale to measure text in either way (lib/tui.sh). The screen is
# the terminal's alternate one, so the summary lands where the loop started.
# The dashboard's state: read by lib/tui.sh, which a linter reading this file cannot see.
# shellcheck disable=SC2034
_aif_work_loop_tui_start() {
  local cl
  AIF_WORK_LOOP_TUI=0
  [ "${1:-auto}" != off ] && [ "${AIF_NO_TUI:-}" != 1 ] && [ -t 2 ] && [ "${TERM:-dumb}" != dumb ] || return 0
  { : </dev/tty; } 2>/dev/null || return 0
  AIF_WORK_LOOP_TUI=1
  AIF_TUI_COLOR=1
  [ -z "${NO_COLOR:-}" ] || AIF_TUI_COLOR=0
  AIF_TUI_256=0
  [ "$(tput colors 2>/dev/null || printf 8)" -lt 256 ] 2>/dev/null || AIF_TUI_256=1
  cl="${LC_CTYPE:-${LANG:-}}"
  case "$cl" in
    *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*)
      AIF_TUI_UNICODE=1
      AIF_TUI_UTF8="$cl"
      ;;
    *)
      AIF_TUI_UNICODE=0
      AIF_TUI_UTF8="$(locale -a 2>/dev/null | grep -iE '^(C|en_US)\.UTF-?8$' | sed -n 1p)" || AIF_TUI_UTF8=""
      ;;
  esac
  aif_tui_init
  _aif_work_loop_typical
  printf '\033[?1049h\033[?25l' >&2
}

# _aif_work_loop_tui_stop — the terminal as it was: the cursor back, the
# alternate screen left. Safe to call twice.
_aif_work_loop_tui_stop() {
  [ "${AIF_WORK_LOOP_TUI:-0}" = 1 ] || return 0
  AIF_WORK_LOOP_TUI=0
  printf '\033[?25h\033[?1049l' >&2
}

# _aif_work_loop_typical — how long each station usually takes here, in
# seconds: the median of what the stations' kept envelopes say
# (tasks/<ID>/stations/*.json, duration_ms). What a worker's bar measures a
# stage against; 10, 10 and 15 minutes where this project has no history yet.
# The dashboard's state: read by lib/tui.sh, which a linter reading this file cannot see.
# shellcheck disable=SC2034
_aif_work_loop_typical() {
  local typ kv
  AIF_TUI_TYP_plan=600 AIF_TUI_TYP_tests=600 AIF_TUI_TYP_implement=900
  typ="$(find "$AIF_WORK_LOOP_MAIN/tasks" -path '*/stations/*.json' -type f -print0 2>/dev/null |
    xargs -0 jq -c '{ f: input_filename, d: (.duration_ms // null) }' 2>/dev/null |
    jq -rs '[ .[] | select(.d != null) | { s: (.f | capture("/[0-9]+-(?<s>[a-z]+)\\.json$").s), d } ]
      | group_by(.s) | .[] | "\(.[0].s)=\(map(.d) | sort | .[length / 2 | floor] / 1000 | floor)"' 2>/dev/null)" || typ=""
  for kv in $typ; do
    case "$kv" in
      plan=[1-9]*) AIF_TUI_TYP_plan="${kv#plan=}" ;;
      tests=[1-9]*) AIF_TUI_TYP_tests="${kv#tests=}" ;;
      implement=[1-9]*) AIF_TUI_TYP_implement="${kv#implement=}" ;;
    esac
  done
}

# _aif_work_loop_tick — a second of the loop: with the dashboard, a frame and a
# key (the key's read is the second); without, a sleep. `|| true` on both: a
# Ctrl-C reaches what the loop runs in the foreground as well as the loop,
# and under set -e a command it ended would end the loop with it.
_aif_work_loop_tick() {
  local key=""
  if [ "${AIF_WORK_LOOP_TUI:-0}" != 1 ]; then
    sleep 1 || true
    return 0
  fi
  _aif_work_loop_refresh
  _aif_work_loop_draw
  IFS= read -r -t 1 -n 1 -s key </dev/tty 2>/dev/null || true
  [ -z "$key" ] || _aif_work_loop_key "$key"
}

# _aif_work_loop_refresh — what the frame shows: each worker's live state from
# its run lock, the cards in Ready it has not taken (every 30 seconds — on a
# Trello board a look is a request), the machine's load and free disk (every
# 10), and the selected worker's log when that is on screen.
# The dashboard's state: read by lib/tui.sh, which a linter reading this file cannot see.
# shellcheck disable=SC2034
_aif_work_loop_refresh() {
  local i now lock id out="" l c
  now="$(date +%s)"
  AIF_TUI_NOW="$now"
  for i in $(seq 1 "$AIF_TUI_PARALLEL"); do
    [ "${AIF_LS_RESULT[i]}" = running ] || continue
    lock="$(aif_run_lock_dir "$AIF_WORK_LOOP_ROOT" "${AIF_LS_ID[i]}")"
    [ ! -f "$lock/live.json" ] || AIF_LS_LIVE[i]="$(cat "$lock/live.json" 2>/dev/null)" || true
  done
  if [ "$now" -ge "${AIF_WORK_LOOP_SHOW_POLL:-0}" ]; then
    AIF_WORK_LOOP_SHOW_POLL=$((now + 30))
    AIF_WORK_LOOP_READY="$(aif_board_ready_list "$AIF_WORK_LOOP_ROOT" 2>/dev/null)" || AIF_WORK_LOOP_READY=""
  fi
  # What it read, less what it has taken since: the card a worker took a
  # second ago is not still waiting.
  for id in ${AIF_WORK_LOOP_READY:-}; do
    case "$AIF_WORK_LOOP_TAKEN" in
      *" $id "*) ;;
      *) out="$out $id" ;;
    esac
  done
  AIF_TUI_READY="${out# }"
  if [ "$now" -ge "${AIF_WORK_LOOP_SYS_POLL:-0}" ]; then
    AIF_WORK_LOOP_SYS_POLL=$((now + 10))
    l="$(sysctl -n vm.loadavg 2>/dev/null | awk '{ print $2 }')" || l=""
    [ -n "$l" ] || l="$(awk '{ print $1 }' /proc/loadavg 2>/dev/null)" || l=""
    c="$(sysctl -n hw.ncpu 2>/dev/null)" || c=""
    [ -n "$c" ] || c="$(getconf _NPROCESSORS_ONLN 2>/dev/null)" || c=""
    AIF_TUI_LOAD="${l:-?}/${c:-?}"
    AIF_TUI_DISK="$(df -Pk "$AIF_WORK_LOOP_MAIN" 2>/dev/null | awk 'NR == 2 { printf "%.0f GB free", $4 / 1048576 }')" || AIF_TUI_DISK=""
  fi
  if [ "$AIF_TUI_BOTTOM" = log ]; then
    AIF_TUI_LOG="$(tail -n 6 "$AIF_WORK_LOOP_LOGDIR/${AIF_LS_ID[AIF_TUI_SEL]}.log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')" || AIF_TUI_LOG=""
  fi
}

# _aif_work_loop_draw — one frame, written at once: home, each line with its
# rest cleared, the rest of the screen cleared. Sized to the terminal as it is
# now, so a resize is drawn on the next second.
# The dashboard's state: read by lib/tui.sh, which a linter reading this file cannot see.
# shellcheck disable=SC2034
_aif_work_loop_draw() {
  local size rows cols
  size="$(stty size </dev/tty 2>/dev/null)" || size=""
  rows="${size% *}"
  cols="${size#* }"
  # A terminal that has never been told its size says 0 0; tput, which asks
  # through a pipe here, would answer with its database's 24 by 80.
  case "$rows" in
    '' | *[!0-9]* | 0) rows=40 ;;
  esac
  case "$cols" in
    '' | *[!0-9]* | 0) cols=100 ;;
  esac
  AIF_TUI_ROWS="$rows" AIF_TUI_COLS="$cols"
  if [ -n "${AIF_TUI_ASK:-}" ]; then
    AIF_TUI_STATUS="stop ${AIF_LS_ID[AIF_TUI_ASK]}? y: yes, any key: no" AIF_TUI_STATUS_TONE=yellow
  elif [ -n "$AIF_WORK_LOOP_KILLED" ]; then
    AIF_TUI_STATUS="stopping every run in flight" AIF_TUI_STATUS_TONE=red
  elif [ -n "$AIF_WORK_LOOP_STOP" ]; then
    AIF_TUI_STATUS="no new cards — ^C again: stop all" AIF_TUI_STATUS_TONE=yellow
  else
    AIF_TUI_STATUS="^C or q: no new cards" AIF_TUI_STATUS_TONE=dim
  fi
  aif_tui_frame
  printf '\033[H%s\033[K\033[J' "${AIF_TUI_FRAME//$'\n'/$'\033[K\n'}" >&2
}

# _aif_work_loop_key <key> — what a key does: 1–9 selects a worker, s stops the
# selected one (after a y — it is a run, and its card goes to Needs Human),
# l shows its log or the events again, q is the first Ctrl-C.
_aif_work_loop_key() {
  local k="$1" id
  if [ -n "${AIF_TUI_ASK:-}" ]; then
    id="${AIF_LS_ID[AIF_TUI_ASK]}"
    if [ "$k" = y ] && [ -n "$id" ] && [ "${AIF_LS_RESULT[AIF_TUI_ASK]}" = running ]; then
      _aif_work_loop_event yellow "$id: stopping it, as asked"
      ("$AIF_ROOT/bin/aif" work "$id" --stop </dev/null >>"$AIF_WORK_LOOP_LOGDIR/loop.log" 2>&1) &
    fi
    AIF_TUI_ASK=""
    return 0
  fi
  case "$k" in
    [1-9]) [ "$k" -gt "$AIF_TUI_PARALLEL" ] || AIF_TUI_SEL="$k" ;;
    s) [ "${AIF_LS_RESULT[AIF_TUI_SEL]}" != running ] || AIF_TUI_ASK="$AIF_TUI_SEL" ;;
    l)
      if [ "$AIF_TUI_BOTTOM" = log ]; then
        AIF_TUI_BOTTOM=events
      else
        AIF_TUI_BOTTOM=log
      fi
      ;;
    q) _aif_work_loop_signal INT ;;
  esac
  return 0
}

# _aif_work_loop_signal <EXIT|INT|TERM> — the loop's handler, and what Ctrl-C
# means to a loop: the first takes no new card and lets the runs in flight
# finish; the second stops them, each settling its card as stopped by Ctrl-C.
# A TERM stops them at once. It records and forwards, and returns — the loop
# goes on from where the signal found it, waits for the runs, and says how
# each ended.
_aif_work_loop_signal() {
  case "${1:-}" in
    INT)
      AIF_WORK_LOOP_CTRL_C=$((AIF_WORK_LOOP_CTRL_C + 1))
      if [ "$AIF_WORK_LOOP_CTRL_C" -eq 1 ]; then
        [ -n "$AIF_WORK_LOOP_STOP" ] || AIF_WORK_LOOP_STOP="stopped by Ctrl-C — no new card taken"
        [ -z "$AIF_WORK_LOOP_RUNNING" ] ||
          _aif_work_loop_event yellow "Ctrl-C — no new card; the runs in flight finish on their own. Ctrl-C again stops them."
      else
        AIF_WORK_LOOP_STOP="stopped by Ctrl-C twice — the runs in flight were stopped too"
        _aif_work_loop_forward INT
      fi
      ;;
    TERM)
      AIF_WORK_LOOP_STOP="stopped by a TERM — the runs in flight were stopped too"
      _aif_work_loop_forward TERM
      ;;
    EXIT)
      # The loop itself failing: the terminal back first, then its workers —
      # processes of their own, which go on, each settling its own card.
      _aif_work_loop_tui_stop
      [ -z "${AIF_WORK_LOOP_RUNNING:-}" ] ||
        aif_warn "the loop ended with runs still in flight ($AIF_WORK_LOOP_RUNNING) — each settles its own card; aif work <ID> --stop ends one"
      ;;
  esac
  return 0
}

# _aif_work_loop_forward <INT|TERM> — the signal to every run in flight, to its
# whole process group: the worker, its station, its suite.
_aif_work_loop_forward() {
  local entry
  AIF_WORK_LOOP_KILLED="$1"
  for entry in $AIF_WORK_LOOP_RUNNING; do
    kill -"$1" -- "-${entry%%:*}" 2>/dev/null || kill -"$1" "${entry%%:*}" 2>/dev/null || true
  done
  [ -z "$AIF_WORK_LOOP_RUNNING" ] || _aif_work_loop_event red "stopping every run in flight ($1)"
}

aif_cmd_work() {
  local ticket="" profile="" budget="" max_minutes="" use_worktree=1 clean=0
  local loop=0 max_tickets=0 stop=0 parallel="" profile_arg tui=auto
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
      --stop) stop=1 ;;
      --no-tui) tui=off ;;
      --loop) loop=1 ;;
      --max-tickets)
        shift
        max_tickets="${1:-}"
        case "$max_tickets" in
          '' | *[!0-9]* | 0) aif_die "--max-tickets takes a positive whole number" ;;
        esac
        ;;
      --parallel)
        shift
        parallel="${1:-}"
        case "$parallel" in
          '' | *[!0-9]* | 0) aif_die "--parallel takes a positive whole number — how many tickets the loop builds at once" ;;
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
  # (docs/DEFECTS.md 3.11). Now the caller has to say so: CI jobs already
  # carry CI=1, and a harness sets AIF_DISPOSABLE=1 for its sandboxes.
  if [ "$use_worktree" -eq 0 ] && [ "$clean" -eq 0 ] && [ "$stop" -eq 0 ] &&
    [ -z "${CI:-}" ] && [ "${AIF_DISPOSABLE:-}" != "1" ]; then
    aif_die "--no-worktree runs every station with bypassPermissions in THIS checkout, and nothing here says it is disposable. In CI, CI=1 already does; anywhere else: AIF_DISPOSABLE=1 aif work ${ticket:-<ticket>} --no-worktree"
  fi

  local root
  root="$(aif_require_project)"

  if [ "$stop" -eq 1 ]; then
    [ -n "$ticket" ] || aif_die "usage: aif work <ticket> --stop"
    [ "$loop" -eq 0 ] && [ "$clean" -eq 0 ] ||
      aif_die "--stop stops one run and does nothing else — not with --loop or --clean"
    if _aif_work_stop "$root" "$ticket"; then
      return 0
    fi
    exit 1
  fi

  if [ "$clean" -eq 1 ]; then
    [ -n "$ticket" ] || aif_die "usage: aif work <ticket> --clean"
    # Not from under a run: the worktree is where its stations are writing.
    if _aif_work_lock_live "$(aif_run_lock_dir "$root" "$ticket")"; then
      aif_die "a worker is building $ticket in that worktree right now — stop it first: aif work $ticket --stop"
    fi
    local wt_c="$root/$AIF_WORK_WORKTREES/$ticket"
    [ -e "$wt_c" ] || aif_die "no worktree for $ticket at ${wt_c#"$root"/}"
    git -C "$root" worktree remove --force "$wt_c" >/dev/null 2>&1 || rm -rf "$wt_c"
    git -C "$root" worktree prune >/dev/null 2>&1 || true
    printf '%sremoved%s %s — branch aif/%s is untouched\n' "$AIF_C_GREEN" "$AIF_C_RESET" "${wt_c#"$root"/}" "$ticket"
    return 0
  fi

  profile_arg="$profile"
  if [ -z "$profile" ]; then
    if [ -f "$root/$AIF_PROFILE_STATE" ]; then
      profile="$(cat "$root/$AIF_PROFILE_STATE")"
    else
      aif_die "no profile — run 'aif init' or pass --profile"
    fi
  fi

  if [ "$loop" -eq 1 ]; then
    [ -z "$ticket" ] || aif_die "--loop takes no ticket: it drains the board's Ready column in the board's order"
    # Two at a time unless told, each in a worktree of its own. --no-worktree
    # runs in THIS checkout, and two runs cannot share one.
    if [ -z "$parallel" ]; then
      parallel=2
      [ "$use_worktree" -eq 1 ] || parallel=1
    elif [ "$parallel" -gt 1 ] && [ "$use_worktree" -eq 0 ]; then
      aif_die "--parallel $parallel needs a worktree per ticket, and --no-worktree runs every ticket in this checkout — drop one of the two"
    fi
    # Once, for every worker the loop starts (_aif_work_loop says why).
    _aif_work_preflight "$root" "$profile"
    _aif_work_loop "$root" "$max_tickets" "$profile_arg" "$budget" "$budget_off" "$max_minutes" "$use_worktree" "$parallel" "$tui"
  fi
  [ "$max_tickets" -eq 0 ] || aif_die "--max-tickets only means something with --loop"
  [ -z "$parallel" ] || aif_die "--parallel only means something with --loop"

  _aif_work_preflight "$root" "$profile"

  # No ticket named: the board decides. The top of Ready is the project
  # manager's order, and the worker consumes it — queue policy is theirs, the
  # queue is not.
  if [ -z "$ticket" ]; then
    ticket="$(aif_board_next_ready "$root")"
    [ -n "$ticket" ] || aif_die "nothing in the board's Ready column — write a ticket with /aif-ba, or name one: aif work <ticket>"
    _aif_work_say "board" "next in Ready: $ticket"
  fi

  # The lock, then the card, then the checkout.
  #
  # The card used to move only once the worktree was proven usable, on the
  # reasoning that a card that never moved needs nothing put back. But a card
  # that never moved is a card still at the top of Ready: the next run — the
  # loop's next pass, or a second worker beside this one — takes it again, and
  # nobody looking at the board can see why it never moved, because the reason
  # was in this terminal. So the card is taken first, and from here every way
  # out ends with it in Review, or in Needs Human with a comment saying why —
  # a machine that cannot run the suite included (blocked: environment).
  if ! _aif_work_lock "$root" "$ticket"; then
    aif_err "$ticket is being built by another worker on this machine ($AIF_WORK_LOCK_HELD). Nothing was spent, and its card was not touched. To stop that run: aif work $ticket --stop"
    exit 3
  fi
  # The handler is armed rather than written inline so that a library taking
  # a trap of its own puts it back instead of clearing it (lib/common.sh). Its
  # subject travels in globals: on EXIT the locals may already be gone. Armed
  # with the lock, so that every way out releases it; the card becomes its
  # business once AIF_WORK_CARD names it.
  AIF_WORK_ROOT="$root"
  AIF_WORK_CARD=""
  AIF_WORK_WORK=""
  AIF_WORK_SETTLED=0
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  _aif_work_live '.ticket = $t | .started = $s' --arg t "$ticket" --argjson s "$(date +%s)"
  _aif_work_phase claim
  aif_trap_arm "_aif_work_abandon"

  # A ticket handed over by id that has no card yet gets one on the local
  # board — the worker is the consumer, and a ticket named by hand is
  # implicitly ready; on a trello board the card IS the ticket, so it has to
  # be there already.
  if [ "$(aif_board_kind "$root")" = "local" ] && [ ! -f "$(aif_board_local_dir "$root")/$ticket.json" ] &&
    [ -f "$(aif_task_dir "$root" "$ticket")/ticket.md" ]; then
    (aif_board_create "$root" "$(aif_task_dir "$root" "$ticket")/ticket.md" ready >/dev/null) || true
  fi
  if ! (aif_board_move "$root" "$ticket" in_progress >/dev/null); then
    aif_err "could not move $ticket to In Progress on the board — nothing was spent."
    exit 3
  fi
  AIF_WORK_CARD="$ticket"

  _aif_work_phase worktree
  local wt fresh=0 cut_err cut_why guide_err
  if [ "$use_worktree" -eq 1 ]; then
    # Decided here, not inside the helper: it runs in a $(…) and a flag it set
    # would die with the subshell — and so would its error, which is why that
    # is held, shown, and carried to the card.
    [ -e "$root/$AIF_WORK_WORKTREES/$ticket/.git" ] || fresh=1
    cut_err="$(mktemp "${TMPDIR:-/tmp}/aif-cut-XXXXXX")"
    if ! wt="$(_aif_work_worktree "$root" "$ticket" 2>"$cut_err")"; then
      cat "$cut_err" >&2
      cut_why="$(sed 's/\x1b\[[0-9;]*m//g; s/^error: //' "$cut_err" | sed -n 1p)" || cut_why=""
      rm -f "$cut_err"
      _aif_work_refuse "$root" "$ticket" "could not check out a worktree for $ticket${cut_why:+: $cut_why}"
    fi
    rm -f "$cut_err"
    [ "$fresh" -eq 0 ] || _aif_work_say "worktree" "cut ${wt#"$root"/} on aif/$ticket"
    # Before the probe and before anything reads the branch's copy of the set:
    # a branch cut under an older set is brought up to this checkout's, and
    # the guide with it (docs/DEFECTS.md 9.1).
    _aif_work_set_forward "$root" "$wt" "$ticket"
    _aif_work_ready_worktree "$root" "$wt" "$ticket" ||
      _aif_work_refuse "$root" "$ticket" "$AIF_WORK_ENV_WHY" "$AIF_WORK_ENV_MORE"
    # Preflight saw the developer's guide, and the set was just brought
    # forward, so the worktree has it too. What is left is a checkout whose
    # guide could not be copied — a file in the way, a permission — and that
    # is said as what it is, not as "commit it": for one release this line
    # told a developer whose guide WAS committed to commit it, because the
    # branch predated the file (docs/DEFECTS.md 9.1).
    if [ ! -f "$(aif_guide_path "$wt")" ]; then
      guide_err="$(mktemp "${TMPDIR:-/tmp}/aif-guide-XXXXXX")"
      printf 'The stations read the guide from the worktree, %s. The checkout has it at %s and it could not be brought onto branch aif/%s — look at what is in the way there.\n' \
        "${wt#"$root"/}" "$AIF_GUIDE_FILE" "$ticket" >"$guide_err"
      aif_err "$AIF_GUIDE_FILE could not be brought onto branch aif/$ticket, where the stations run. Nothing was spent."
      _aif_work_refuse "$root" "$ticket" "$AIF_GUIDE_FILE could not be brought onto branch aif/$ticket" "$guide_err"
    fi
  else
    wt="$root"
  fi
  _aif_work_say "worktree" "${wt#"$root"/}"

  _aif_work_phase intake
  local intake_rc=0 nr nr_why
  AIF_WORK_NOT_READY=""
  _aif_work_intake "$root" "$wt" "$ticket" || intake_rc=$?
  if [ "$intake_rc" -eq 3 ]; then
    nr="$(mktemp "${TMPDIR:-/tmp}/aif-pull-XXXXXX")"
    printf '%s\n' "${AIF_WORK_NOT_READY:-the board did not answer}" | sed 's/^/    /' >"$nr"
    _aif_work_refuse "$root" "$ticket" "could not pull $ticket from the board, so there were no bytes to build" "$nr"
  fi
  if [ "$intake_rc" -ne 0 ]; then
    # Not ready, or no ticket at all. Either way nothing has been spent, and
    # the card goes where a human will see it with the reason attached.
    if [ "$intake_rc" -eq 2 ]; then
      nr_why="not ready — the ready gate's questions are below, for the analyst"
    elif [ -n "$AIF_WORK_NOT_READY" ]; then
      nr_why="$(printf '%s\n' "$AIF_WORK_NOT_READY" | sed 's/^error: //' | sed -n 1p)"
    else
      nr_why="no ticket to build: $AIF_TASKS_DIR/$ticket/ticket.md does not exist in this checkout"
    fi
    nr="$(mktemp "${TMPDIR:-/tmp}/aif-not-ready-XXXXXX")"
    {
      printf '# %s — not ready\n\n' "$ticket"
      printf 'The worker refused the ticket at intake and spent nothing. Each line below\n'
      printf 'is a question for the analyst (/aif-ba), not a defect in the build:\n\n'
      printf '%s\n' "${AIF_WORK_NOT_READY:-the ticket does not exist in this checkout}" | sed 's/^/    /'
    } >"$nr"
    _aif_work_block "$root" "$ticket" ticket "$nr_why" "$nr" || true
    AIF_WORK_SETTLED=1
    rm -f "$nr"
    exit 1
  fi

  local work project attempts_max run_max dispatches_max started
  work="$(aif_task_dir "$wt" "$ticket")"
  AIF_WORK_WORK="$work"
  project="$(aif_project_config "$wt")"
  # 16, as the templates say since the stage gained its two loops (a repair,
  # a replan) on top of the three stations' retries (docs/REBUILD-4.md §2.4).
  # A project.json from before the key ran the new stage on the old 12
  # (docs/DEFECTS.md 8.4); the fallback is now the number the stage was
  # budgeted for.
  dispatches_max="$(jq -r '.limits.run_dispatches_max // 16' "$project")"
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  _aif_work_live '.title = $t | .dispatches_max = $d | .dispatches = 0' \
    --arg t "$(_aif_board_title "$work/ticket.md")" --argjson d "$dispatches_max"
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
  _aif_work_phase run
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
      # Built — and before it says so, brought onto the branch it lands on
      # (_aif_work_sync). A build that cannot be is built again from that
      # branch, here, with this run's clock and caps started over.
      budget_left=""
      if [ -n "$budget" ]; then
        budget_left="$(awk -v b="$budget" -v s="$spent" 'BEGIN { r = b - s; if (r < 0.01) r = 0.01; printf "%.2f", r }')"
      fi
      rc=0
      _aif_work_sync "$root" "$wt" "$ticket" "$budget_left" "$dispatches" || rc=$?
      dispatches=$((dispatches + AIF_WORK_SYNC_DISPATCHES))
      spent="$(awk -v s="$spent" -v c="$AIF_WORK_SYNC_SPENT" 'BEGIN { printf "%.4f", s + c }')"
      # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags below
      aif_run_update "$work" '.dispatches = $d | .spent_usd = $s' --argjson d "$dispatches" --argjson s "$spent"
      case "$rc" in
        0)
          status="built"
          break
          ;;
        1)
          _aif_work_say "sync" "$(printf '%s\n' "$AIF_WORK_SYNC_WHY" | sed -n 1p) — the ticket is built again from it"
          # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
          _aif_work_live '.last = $l | .last_tone = "retry"' --arg l "could not be brought onto the branch it lands on — built again from it"
          rc=0
          _aif_work_rebuild "$root" "$wt" "$ticket" "$AIF_WORK_SYNC_WHY" || rc=$?
          if [ "$rc" -eq 0 ]; then
            complaint="$AIF_WORK_REBUILD_COMPLAINT"
            prev_sha=""
            prev_stage=""
            dispatches=0
            spent=0
            started="$(date +%s)"
            continue
          fi
          status="stopped"
          why="$AIF_WORK_REBUILD_WHY"
          break
          ;;
        *)
          status="stopped"
          why="the branch could not be brought onto the branch it lands on — the environment, not the ticket: $AIF_WORK_SYNC_WHY"
          break
          ;;
      esac
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
      # (docs/DEFECTS.md 3.8, aif_g_dispatch_base in the gates' _lib.sh).
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
      # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
      _aif_work_live '.stage = $s | .attempt = $a | .attempts_max = $m | .dispatches = $d | .stage_started = $t' \
        --arg s "$stage" --argjson a "$((attempts + 1))" --argjson m "$attempts_max" \
        --argjson d "$dispatches" --argjson t "$(date +%s)"
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
        # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
        _aif_work_live '.last = $l | .last_tone = "retry"' --arg l "$stage: the dependencies it left do not install"
        _aif_work_say "prepare" "$stage rejected (attempt $((attempts + 1))/$attempts_max) — the dependencies it left do not install; retrying with prepare's output"
        continue
      fi

      # The tool writes the provenance the station was never asked to carry.
      # Its failure is the tool's, never the station's — and it used to be
      # silent: an unstamped plan is rejected by verify-red as "bound to a
      # different ticket", the station rewrites the same plan, and the loop
      # repeats to the cap, billing a tool defect to the human as opus retries
      # (docs/DEFECTS.md 3.7). So it stops, and says whose fault it was.
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
            # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
            _aif_work_live '.last = $l | .last_tone = "retry"' --arg l "implement: the contract cannot hold it — replanning"
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
        # have carried (docs/DEFECTS.md 3.7).
        if ! tool_out="$("$AIF_ROOT/bin/aif" _commit "$stage" "$ticket" 2>&1)"; then
          status="stopped"
          why="aif _commit failed after $stage was admitted — the tool, not the station. The verdict is recorded; the commit that seals it is not, and the next station's baseline would be wrong:
$(printf '%s' "$tool_out" | sed 's/\x1b\[[0-9;]*m//g' | sed -n '1,10p')"
          break
        fi
        complaint=""
        prev_sha=""
        # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
        _aif_work_live '.last = $l | .last_tone = "ok"' --arg l "$stage admitted"
        # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags below
        aif_run_update "$work" '.stage = $n' --arg n "$(aif_run_next "$stage")"
        ;;
      1)
        # sed -n, not head: a gate's output is not bounded, and a head that
        # leaves early under set -e would end the run at the moment of the
        # rejection it was quoting (docs/DEFECTS.md 5.3).
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
        # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
        _aif_work_live '.last = $l | .last_tone = "retry"' \
          --arg l "$stage rejected ($((attempts + 1))/$attempts_max): $(printf '%s\n' "$complaint" | sed -n 1p)"
        _aif_work_say "gate" "$stage rejected (attempt $((attempts + 1))/$attempts_max) — retrying with the complaint"
        ;;
      2)
        # The ticket's: a criterion already true, unfalsifiable, in conflict,
        # undecided. Nothing is retried; the analyst gets the gate's lines.
        status="spec"
        why="$(sed 's/\x1b\[[0-9;]*m//g' "$gate_out" | grep -v '^[[:space:]]*$' | sed -n '1,30p')"
        # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
        _aif_work_live '.last = $l | .last_tone = "stop"' --arg l "$stage: the ticket's problem — back to the analyst"
        break
        ;;
      4)
        # The oracle's: the tests station repairs it in a copy without the
        # implementation, and the implementation is judged again.
        budget_left=""
        if [ -n "$budget" ]; then
          budget_left="$(awk -v b="$budget" -v s="$spent" 'BEGIN { r = b - s; if (r < 0.01) r = 0.01; printf "%.2f", r }')"
        fi
        # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
        _aif_work_live '.last = $l | .last_tone = "retry"' --arg l "green: a frozen test is wrong — the tests station repairs it"
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
        # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
        _aif_work_live '.last = $l | .last_tone = "stop"' --arg l "$stage: no verdict — the run stops"
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
  _aif_work_phase report
  _aif_work_report "$root" "$wt" "$ticket" "$status" "$why" "$started"

  # The report goes where the human looks — the card — and the card moves to
  # where the human decides: Review when it is built, Needs Human when it is
  # not, under the line that says whose problem stopped it. Loud on failure,
  # with the exact command to do it by hand; the work is on the branch either
  # way, and the exit code says what the work is.
  #
  # "report posted" is said when it was: it used to follow the MOVE, and was
  # printed under the very error that said the comment had been refused
  # (docs/DEFECTS.md 10.1). A report too long for a comment is cut by the
  # board adapter, naming where the whole of it is — on the branch.
  local col report_path kind headline full_at branch posted=0
  report_path="$work/report.md"
  branch="$(aif_run_get "$work" '.branch')" || branch=""
  full_at="$AIF_TASKS_DIR/$ticket/report.md on branch ${branch:-aif/$ticket}"
  col=review
  [ "$status" = "built" ] || col=needs_human
  if [ "$col" = "review" ]; then
    if (AIF_BOARD_BY="aif work" AIF_BOARD_FULL_AT="$full_at" aif_board_comment "$root" "$ticket" "$report_path" >/dev/null); then
      posted=1
    else
      aif_warn "the report did not reach the card — post it when the board answers: aif board comment $ticket ${report_path#"$root"/}"
    fi
    if ! (aif_board_move "$root" "$ticket" "$col" >/dev/null); then
      aif_warn "could not move $ticket to $col on the board — run: aif board move $ticket $col"
    elif [ "$posted" -eq 1 ]; then
      _aif_work_say "board" "$ticket → $col, report posted"
    else
      _aif_work_say "board" "$ticket → $col, report NOT on the card (above)"
    fi
  else
    # A spec stop is the ticket's own problem, found by a station — the
    # analyst's. Whatever else stopped the run is the run's.
    kind=run
    [ "$status" != "spec" ] || kind=ticket
    headline="$(printf '%s\n' "$why" | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^[[:space:]]*$' | sed -n 1p)" || headline=""
    [ -n "$headline" ] || headline="the run stopped at $(aif_run_get "$work" '.stage')"
    _aif_work_block "$root" "$ticket" "$kind" "$headline" "$report_path" "$full_at" || true
  fi
  AIF_WORK_SETTLED=1
  [ "$status" = "built" ]
}
