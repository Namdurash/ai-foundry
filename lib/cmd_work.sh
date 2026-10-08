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
# already taken is in Needs Human saying what), or the card is not this
# worker's to take — a dead run's process still runs there, or on Trello
# another machine's worker has claimed it (nothing spent, the card left as it
# is; the loop reads which from the line it said) · 130 / 143 stopped by Ctrl-C,
# by `aif work <ID> --stop` or by a TERM (the card says which) · 129 stopped
# by a hang-up — the terminal closed over it.

# AIF_WORK_WORKTREES lives in lib/paths.sh: `aif doctor` needs it too, to tell
# a project whose test runner is collecting these checkouts beside the real tree.

# How many times one run may be taken over from a worker that died outright —
# each time resumed, its caps fresh — before the next worker stops instead of
# resuming it: workers that die the same way three times are the run's
# problem, not bad luck (docs/DEFECTS.md 14.5; _aif_work_intake).
AIF_WORK_TAKEOVERS_MAX=3

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
    aif work --loop --idle      the same, then waits for Ready to fill instead of ending
    aif work --loop --drain     the loop on this checkout takes no new card, from any terminal
    aif work --loop --stop      …and stops its runs in flight too, each card saying who
    aif work --status [OPES-52] what this machine knows of a run, read offline

  Every transition goes through the board (aif board). The card moves to In
  Progress first, before the checkout is cut, and ends in Review with the
  report as a comment — or in Needs Human with a comment whose first line
  says why: blocked: ticket | run | environment | stopped. One worker builds
  a ticket at a time on this machine; a second is refused, nothing spent.
  The worker's taken: comment on the card beats (· alive at <time>) at every
  station it starts; on a Trello board two machines share, a card another
  machine's live worker has claimed is skipped and said (exit 3), and of two
  that take one card at once the earlier claim builds it.

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
                     Ready, it resumes where it stopped. With --loop and no
                     ticket: the loop on this checkout takes no new card and
                     stops every run in flight, each card saying who; waits
                     up to 90 s for it to end and says how it did
  --drain            with --loop and no ticket: the loop on this checkout
                     takes no new card, and ends once its runs in flight have
                     finished
  --status           what this machine knows of the ticket's run, offline —
                     its lock and whether its worker is alive, what a dead
                     worker left running, its worktree, branch, run record and
                     report — as one line: <ID>  <class> — <why>. With no
                     ticket, every ticket with a run lock, a worktree or a
                     branch here. Touches nothing, asks no board
  --json             with --status: the object (an array with no ticket),
                     as a supervisor reads it
  --loop             build every card in Ready, in the board's order, each in a
                     worktree of its own, until Ready is empty. One loop per
                     checkout: a second is refused (exit 3). Workers start
                     one after another, each once the last one's worktree is
                     ready. A run that cannot start — the environment, not the
                     card — has the machine checked again: the loop goes on
                     while the preflight passes, and stops when it fails or at
                     the third such run in a row. Takes no new card after two
                     that did not build — two cards in Needs Human usually
                     mean the problem is not the cards. While the runner's
                     usage limit pauses its workers it takes no new card
                     either, and goes on once the limit resets; a limit with
                     no reset within 12 hours stops it. Ctrl-C takes no new card
                     and lets the runs in flight finish; Ctrl-C again stops them.
                     --stop on one run stops that one, and its slot goes on.
                     Each worker's output is in .aif/tmp/loop-<when>/<ID>.log
                     (<ID>.2.log for a second take of the card, and on), or
                     under AIF_WORK_LOOP_LOGDIR when it names a directory;
                     summary.json there says how the loop ended
  --idle             with --loop: an empty Ready is not the end — the loop
                     looks again every 30 s (AIF_WORK_LOOP_POLL) and takes what
                     comes, a card that came back included, until Ctrl-C, q,
                     aif work --loop --drain or --stop
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

A station the runner cut off is not the station's attempt. The account's
usage limit pauses the run until it resets, when that is within 12 hours —
every worker and the loop on this checkout with it (.aif/state/pause; rm it
to lift the pause) — and the same attempt is dispatched again, the wait
outside the wall clock; a limit that names no reset, or a later one, stops
the run blocked: environment, naming it, and the loop takes no new card. A
runner that did not answer (no output, not JSON, the server's throttle,
overload) is asked again after 1, 5 and 15 minutes, then blocked:
environment. Each wait is in the report and the run's runner_waits.

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

# _aif_work_abandon <EXIT|INT|TERM|HUP> — the card stops claiming that work
# is happening, and says why.
#
# Armed for EXIT, INT, TERM and HUP the moment the run lock is taken, and it
# has to cover all four. Ctrl-C and a supervisor's TERM are the obvious two;
# the common one is neither — it is any `aif_die` or `set -e` failure between
# the claim and the report, which used to leave the card In Progress with
# nobody working on it. That is the same defect as a meter that quietly did
# not fire, and for one release the handler meant to prevent it was disarmed
# by the first ledger write of every run (docs/DEFECTS.md 3.1–3.3). The fourth
# is the terminal closing over a run: the shell hangs up on the worker's whole
# group, the station dies of it, and nothing said so on the card — it stayed
# In Progress, exactly the gap the other three had closed (docs/DEFECTS.md
# 14.8).
#
# It used to move the card and say nothing: whoever opened Needs Human found a
# card with no reason on it, and the reason was in the scrollback of whoever
# had started the run. It posts one now (_aif_work_block) — who stopped the
# run and during which stage, or the last error the worker printed.
#
# Idempotent, and silent once the run has settled the card itself; the run
# lock is released either way. Where it acts it exits 130 for an INT, 143 for
# a TERM, 129 for a HUP and 1 for an exit — a run nobody finished IS "stopped,
# needs a human", which is what 1 means here.
_aif_work_abandon() {
  local rc_in=$? sig="${1:-EXIT}" code=1 kind why stage who
  # `aif work <ID> --stop` waits for this: once the handler runs, the stop has
  # landed, and nothing under the worker is signalled again.
  [ -z "${AIF_WORK_LOCK:-}" ] || : >"$AIF_WORK_LOCK/ack" 2>/dev/null || true
  case "$sig" in
    INT) code=130 ;;
    TERM) code=143 ;;
    HUP) code=129 ;;
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
    elif [ "$sig" = "HUP" ]; then
      kind=stopped
      why="by a hang-up — the terminal closed — during $stage"
    else
      # Before intake no station has run: what stopped it is the machine.
      case "${AIF_WORK_PHASE:-}" in
        claim | worktree | intake) kind=environment ;;
        *) kind=run ;;
      esac
      why="the worker exited (code $rc_in) during $stage"
      [ -z "${AIF_LAST_ERR:-}" ] || why="$why; the last error it printed: $AIF_LAST_ERR"
    fi
    # Stopped while it waited on the runner — a limit's pause, a backoff: the
    # card says so, and the attempt the stage loop counted for the dispatch
    # is taken back, since nothing judged it — back in Ready, the card
    # resumes the same attempt (docs/DEFECTS.md 13.7).
    if [ -n "${AIF_WORK_WAITING:-}" ]; then
      why="$why, $AIF_WORK_WAITING"
      if [ -n "${AIF_WORK_COUNTED:-}" ] && [ -n "${AIF_WORK_WORK:-}" ]; then
        # shellcheck disable=SC2016  # jq's variable, bound by --arg
        aif_run_update "$AIF_WORK_WORK" '.attempts[$s] = ([((.attempts[$s] // 1) - 1), 0] | max)' \
          --arg s "$AIF_WORK_COUNTED" 2>/dev/null || true
      fi
    fi
    _aif_work_block "$AIF_WORK_ROOT" "$AIF_WORK_CARD" "$kind" "$why" "" || true
    # After a hang-up this terminal may be gone, and a write to it fails;
    # errexit holds inside a trap too (bash 3.2, probed), and a failed print
    # here would end the process with the print's code, not the signal's.
    printf '\n%s did not finish — moved to needs_human, blocked: %s %s; the branch keeps what was accepted\n' \
      "$AIF_WORK_CARD" "$kind" "$why" >&2 || true
    _aif_work_unlock
    exit "$code"
  fi
  _aif_work_unlock
  case "$sig" in
    INT | TERM | HUP) exit "$code" ;;
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

# _aif_work_block_text <ticket> <kind> <why> [<body-file>] — the comment
# alone, on stdout: the line, the next step for its kind, the body. Its own
# function so that a shift that ends before it could make the move a dead
# worker's card was owed leaves the same comment in a file for a person to
# post (lib/cmd_start.sh _aif_start_summary; docs/DEFECTS.md 15.9).
_aif_work_block_text() {
  local ticket="$1" kind="$2" why="$3" body="${4:-}" next
  case "$kind" in
    ticket) next="The ticket's problem, not the build's: the analyst (/aif-ba) reworks it from what is below, and it goes back to Ready." ;;
    run) next="The run stopped short of a build. What was accepted is committed on branch aif/$ticket; back in Ready, the run resumes where it stopped while the ticket is unchanged, and starts over when it changes." ;;
    environment)
      # Mid-run — the runner's limit, a runner that did not answer — stations
      # ran and the branch holds what they had accepted: "no station ran,
      # nothing was spent" is only true before the run (docs/DEFECTS.md 13.7).
      case "${AIF_WORK_PHASE:-}" in
        run | report) next="This machine or the runner, not the ticket: fix what is named below, or let it pass — a limit's reset, the API answering again. What was accepted is committed on branch aif/$ticket; back in Ready once it has passed, the run resumes where it stopped." ;;
        *) next="This machine, not the ticket: no station ran on it, nothing was spent. Fix what is named below, then move the card back to Ready." ;;
      esac
      ;;
    stopped) next="What was accepted is committed on branch aif/$ticket; back in Ready, the run resumes where it stopped while the ticket is unchanged." ;;
    *) next="" ;;
  esac
  printf 'blocked: %s — %s\n' "$kind" "$why"
  [ -z "$next" ] || printf '\n%s\n' "$next"
  if [ -n "$body" ] && [ -s "$body" ]; then
    printf '\n'
    cat "$body"
  fi
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
# The comment is the worker's; AIF_WORK_BLOCK_BY names another voice for the
# one other caller, `aif start`, which settles a dead worker's card in these
# same words (lib/cmd_start.sh, R3c) and says on the card that it was the
# shift that did.
#
# rc 0 posted and moved · 1 either failed, with the command to do it by hand.
_aif_work_block() {
  local root="$1" ticket="$2" kind="$3" why="$4" body="${5:-}" full_at="${6:-}"
  local f keep="" rc=0 said="why posted"
  f="$(mktemp "${TMPDIR:-/tmp}/aif-blocked-XXXXXX")"
  _aif_work_block_text "$ticket" "$kind" "$why" "$body" >"$f"
  if ! (AIF_BOARD_BY="${AIF_WORK_BLOCK_BY:-aif work}" AIF_BOARD_FULL_AT="$full_at" aif_board_comment "$root" "$ticket" "$f" >/dev/null); then
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

# _aif_work_claim <root> <ticket> — stamp the card with who took it: one
# comment whose first line is `taken: <host> pid <pid> at <time> — aif work`.
#
# The move to In Progress says that work is happening; it does not say
# where. On a Trello board shared by two machines that is the whole
# question: a card In Progress is a live worker on the other machine, or a
# card somebody dragged there by hand, and nothing on it told the two apart
# — the run lock that knows the pid is in this machine's .aif, where the
# other cannot look (docs/AUTOPILOT-RESEARCH.md §6.11, verification 5;
# docs/DEFECTS.md 14.4). So the worker says it on the card, in the words the
# lock holds: the host, the pid the lock records, the time. A claim and
# nothing more — the project manager routes on none of it (AIF_BOARD_HEADS,
# lib/board.sh), and the report or the blocked: line that follows is the
# newer head.
#
# Bookkeeping never blocks a build (docs/DEFECTS.md 13.8): a claim that could
# not be posted is a warning, and the run goes on with no host on the card.
#
# The claim's text and its comment id stay in the run lock (`claim.md`,
# `claim.id`): the worker edits that comment while its run lives
# (_aif_work_heartbeat), and withdraws it when another machine claimed the card
# first (_aif_work_claim_race) — both through the comment's id, so neither
# finds the card again (docs/DEFECTS.md 14.4).
_aif_work_claim() {
  local root="$1" ticket="$2" host f idf
  host="$(aif_host_short)"
  f="$(mktemp "${TMPDIR:-/tmp}/aif-taken-XXXXXX")"
  idf="$(mktemp "${TMPDIR:-/tmp}/aif-taken-id-XXXXXX")"
  {
    printf 'taken: %s pid %s at %s — aif work\n' "${host:-?}" "$$" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '\nThe worker on %s has this card; its run lock there records the same pid. A claim, not a reason to route — the comment that follows says how the run ended. While the run lives its first line says when the worker was last alive.\n' "${host:-?}"
  } >"$f"
  if (AIF_BOARD_BY="aif work" AIF_BOARD_COMMENT_ID_TO="$idf" aif_board_comment "$root" "$ticket" "$f" >/dev/null); then
    if [ -n "${AIF_WORK_LOCK:-}" ] && [ -d "$AIF_WORK_LOCK" ]; then
      cp "$f" "$AIF_WORK_LOCK/claim.md" 2>/dev/null || true
      [ ! -s "$idf" ] || cp "$idf" "$AIF_WORK_LOCK/claim.id" 2>/dev/null || true
    fi
  else
    aif_warn "could not post the claim on $ticket — the card shows no host"
  fi
  rm -f "$f" "$idf"
}

# _aif_work_heartbeat — the claim, edited in place to say this worker is alive
# now: its first line `taken: <host> pid <pid> at <time> — aif work · alive at
# <now>`, the rest as posted. At the start of every dispatch — the stage
# loop's, a repair's, a sync's (_aif_work_dispatch) — so a run that lives has
# a claim no older than its longest station, and a claim that has said nothing
# for longer than a run's wall clock is a worker gone: what a shift on another
# machine reads it by, where the run lock that knows the pid cannot be read
# (docs/DEFECTS.md 14.4; lib/start.jq). One request on Trello — the comment by
# its id, no card found. Bookkeeping: a beat the board refused is a dim line,
# never a stop (13.8).
_aif_work_heartbeat() {
  local lock="${AIF_WORK_LOCK:-}" root="${AIF_WORK_ROOT:-}" ticket="${AIF_WORK_CARD:-}" cid f
  [ -n "$lock" ] && [ -n "$root" ] && [ -n "$ticket" ] || return 0
  [ -f "$lock/claim.id" ] && [ -f "$lock/claim.md" ] || return 0
  cid="$(sed -n 1p "$lock/claim.id" 2>/dev/null)" || cid=""
  [ -n "$cid" ] || return 0
  f="$(mktemp "${TMPDIR:-/tmp}/aif-alive-XXXXXX")" || return 0
  {
    printf '%s · alive at %s\n' "$(sed -n 1p "$lock/claim.md")" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    sed -n '2,$p' "$lock/claim.md"
  } >"$f" 2>/dev/null || true
  (aif_board_comment_edit "$root" "$ticket" "$cid" "$f" >/dev/null 2>&1) ||
    _aif_work_say "board" "the claim's heartbeat did not reach $ticket — another machine may read its worker as gone"
  rm -f "$f"
  return 0
}

# _aif_work_claim_life <head-json> — the claims among a card's heads, one JSON
# object a line, oldest first: `{ i, host, pid, life }`, where i is the head's
# place and life the epoch of the last time its worker said it was alive — the
# heartbeat (`· alive at`), else the time the claim names, else the
# comment's own. A jq library of one function, shared by the claim check and
# the race below so that the two read a claim the same way.
_aif_work_claim_life() {
  printf '%s' "$1" | jq -c '
    def epoch: if type == "string" then (try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null) else null end;
    (.heads // []) as $h
    | range(0; $h | length) as $i
    | ($h[$i].line // "") as $l
    | select($l | startswith("taken: "))
    | ($l | capture("^taken: (?<host>[^ ]+) pid (?<pid>[0-9]+) at (?<at>[^ ]+)") // {}) as $c
    | ($l | capture(" · alive at (?<alive>[^ ]+)$") // {}) as $a
    | { i: $i, line: $l, host: ($c.host // null), pid: ($c.pid // null),
        life: ([ ($a.alive | epoch), ($c.at | epoch), ($h[$i].at | epoch) ] | map(select(. != null)) | max) }' 2>/dev/null
}

# _aif_work_claim_check <root> <ticket> — before a take, on Trello: rc 1 when
# the card's newest head is another machine's claim whose worker said it was
# alive within a run's wall clock (limits.run_max_minutes), AIF_WORK_CLAIMED
# naming it; else rc 0.
#
# A take was a read of Ready and a move, with no compare-and-set, and two
# machines on one board that read the same card both moved it and both built
# it; and once it was In Progress, a live worker elsewhere and a card a
# person dragged back to Ready looked the same (docs/DEFECTS.md 14.4). The
# claim says which: a card another machine claimed, and whose worker has said
# since that it lives, is that machine's — skipped, and said. A claim older
# than a run can last is a worker gone (14.1's machine is not this one), and
# the card is taken. A head that cannot be read is no claim: the race after
# the take (_aif_work_claim_race) is the second look. The local board is one
# machine's, and its run lock says all of this already.
_aif_work_claim_check() {
  local root="$1" ticket="$2" hj wall last
  AIF_WORK_CLAIMED=""
  [ "$(aif_board_kind "$root")" = trello ] || return 0
  hj="$( (aif_board_head_json "$root" "$ticket") 2>/dev/null)" || true
  [ -n "$hj" ] || return 0
  case "$(printf '%s' "$hj" | jq -r '.line // ""' 2>/dev/null)" in
    "taken: "*) ;;
    *) return 0 ;;
  esac
  wall="$(jq -r '.limits.run_max_minutes // 120' "$(aif_project_config "$root")" 2>/dev/null)" || wall=120
  case "$wall" in
    '' | *[!0-9]*) wall=120 ;;
  esac
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  last="$(_aif_work_claim_life "$hj" | jq -rs --arg host "$(aif_host_short)" --argjson now "$(date +%s)" --argjson wall "$wall" '
    last // empty | select(.host != null and .host != $host and .life != null and ($now - .life) < $wall * 60)
    | "\(.host) (pid \(.pid // "?"), its worker last said it was alive \((($now - .life) / 60) | floor) min ago — within the wall clock of a run, \($wall) min)"' 2>/dev/null)" || last=""
  [ -n "$last" ] || return 0
  AIF_WORK_CLAIMED="$last"
  return 1
}

# _aif_work_claim_race <root> <ticket> — after this worker's own claim, on
# Trello: rc 1 when another machine claimed the card first, AIF_WORK_CLAIMED
# naming it; else rc 0.
#
# Two machines that read the card before either claimed it both pass the
# check above, both move it and both post a claim. The earliest claim since
# the card's last head that is not a claim wins — the board's order, the one
# both machines read — counting only a claim whose worker lives by the check's
# own rule: a claim gone silent is not a rival (a card a person moved back
# after its worker died is taken, and must stay taken). The loser says so,
# withdraws its claim — edited into a first line no reader routes on, so the
# winner's is the newest `taken:` again, which a shift reads to tell whose
# card it is — and takes nothing: no worktree, the card left to the winner
# (docs/DEFECTS.md 14.4). A read that fails, or a claim this worker could not
# post, is no race found: the build goes on, as it did before.
_aif_work_claim_race() {
  local root="$1" ticket="$2" hj mine wall winner f
  AIF_WORK_CLAIMED=""
  [ "$(aif_board_kind "$root")" = trello ] || return 0
  [ -n "${AIF_WORK_LOCK:-}" ] && [ -f "$AIF_WORK_LOCK/claim.md" ] && [ -f "$AIF_WORK_LOCK/claim.id" ] || return 0
  mine="$(sed -n 1p "$AIF_WORK_LOCK/claim.md" 2>/dev/null)" || mine=""
  [ -n "$mine" ] || return 0
  hj="$( (aif_board_head_json "$root" "$ticket") 2>/dev/null)" || true
  [ -n "$hj" ] || return 0
  wall="$(jq -r '.limits.run_max_minutes // 120' "$(aif_project_config "$root")" 2>/dev/null)" || wall=120
  case "$wall" in
    '' | *[!0-9]*) wall=120 ;;
  esac
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  winner="$(_aif_work_claim_life "$hj" | jq -rs --arg mine "$mine" --arg host "$(aif_host_short)" \
    --argjson now "$(date +%s)" --argjson wall "$wall" '
    . as $claims
    | ([ $claims[] | select(.line == $mine or (.line | startswith($mine + " · alive at "))) | .i ] | last) as $me
    | if $me == null then empty else
        # The claims right before this one, back to the last head that is not one.
        ([ range(0; $me) ] | map(. as $k | select(any($claims[]; .i == $k) | not)) | max // -1) as $stop
        | [ $claims[] | select(.i > $stop and .i < $me)
            | select(.host != null and .host != $host and .life != null and ($now - .life) < $wall * 60) ]
        | .[0] // empty | "\(.host) (pid \(.pid // "?"))"
      end' 2>/dev/null)" || winner=""
  [ -n "$winner" ] || return 0
  AIF_WORK_CLAIMED="$winner"
  f="$(mktemp "${TMPDIR:-/tmp}/aif-lost-XXXXXX")"
  mine="${mine#taken: }"
  {
    printf 'not taken: %s — aif work · %s claimed this card first\n' "${mine% — aif work}" "$winner"
    printf '\nTwo machines took this card at once; the earlier claim stands, and this worker took nothing.\n'
  } >"$f"
  (aif_board_comment_edit "$root" "$ticket" "$(sed -n 1p "$AIF_WORK_LOCK/claim.id")" "$f" >/dev/null 2>&1) ||
    aif_warn "could not withdraw this worker's claim on $ticket — its taken: line names this host while $winner builds it"
  rm -f "$f"
  return 1
}

# _aif_work_repost_kept <root> — every `blocked:` line the board refused, kept
# in .aif/tmp/blocked-<ID>.md (_aif_work_block), put on its card once the board
# answers, before this worker takes a card of its own.
#
# The card went to Needs Human with its comment refused — deliberately: left
# in Ready it would be taken again — and then sat there with no first line to
# route on, the reason on one machine's disk, until someone ran the command
# the warning named (docs/DEFECTS.md 14.2). Posted now when the card is still
# in Needs Human with nothing after the run's own claim on it — its newest
# head this machine's `taken:`, or none — comment only, the move made long
# since; the file removed once the line is up. A card with any other head
# there has moved on (the line posted by hand, a later block, a land), and
# one in Review or Done is past it: the file is stale and removed. In
# Progress is the shift's to settle with the file (lib/start.jq R3c), and
# Ready or Backlog a card a person moved on — left. Taken aside first, so
# that two workers starting at once post it once. A board that does not
# answer keeps every file for the next run. Never a stop.
_aif_work_repost_kept() {
  local root="$1" main host f id col head rc aside
  main="$(aif_main_root "$root")"
  host="$(aif_host_short)"
  for f in "$main/.aif/tmp"/blocked-*.md; do
    [ -f "$f" ] || continue
    id="${f##*/blocked-}"
    id="${id%.md}"
    case "$id" in
      '' | [!A-Za-z0-9]* | *[!A-Za-z0-9._-]*) continue ;;
    esac
    rc=0
    col="$( (aif_board_card_column "$root" "$id") 2>/dev/null)" || rc=$?
    case "$rc" in
      0) ;;
      1)
        rm -f "$f"
        _aif_work_say "board" "$id — no card on the board any more: its kept blocked: line removed"
        continue
        ;;
      *) continue ;;
    esac
    case "$col" in
      needs_human) ;;
      review | done)
        rm -f "$f"
        _aif_work_say "board" "$id — in $col, past the block it kept a line for: .aif/tmp/blocked-$id.md removed"
        continue
        ;;
      *) continue ;;
    esac
    rc=0
    head="$( (aif_board_last_line "$root" "$id") 2>/dev/null)" || rc=$?
    [ "$rc" -le 1 ] || continue
    case "$head" in
      "" | "taken: $host "*) ;;
      *)
        rm -f "$f"
        _aif_work_say "board" "$id — its card says \"$head\" since: the kept blocked: line is stale, removed"
        continue
        ;;
    esac
    aside="$f.posting.$$"
    mv "$f" "$aside" 2>/dev/null || continue
    if (AIF_BOARD_BY="aif work" aif_board_comment "$root" "$id" "$aside" >/dev/null 2>&1); then
      rm -f "$aside"
      _aif_work_say "board" "$id — its blocked: line, refused by the board when it was blocked, is on the card now"
    else
      [ -e "$f" ] || mv "$aside" "$f" 2>/dev/null || true
      rm -f "$aside" 2>/dev/null || true
    fi
  done
  return 0
}

# _aif_work_lock_pid <lock-dir> — the pid that holds the run lock, or empty.
_aif_work_lock_pid() {
  jq -r '.pid // empty' "$1/owner.json" 2>/dev/null
}

# _aif_work_lock_live_as <lock-dir> <glob> — rc 0 when the process behind the
# lock is alive and its command line matches <glob>: the command that takes
# that lock, never just the word.
#
# A pid that is gone is a holder killed outright — kill -9, a closed laptop, a
# reboot — that never ran its handler; one the system has since handed to some
# other program is not a holder either. A lock with no owner written yet was
# taken a moment ago, or by a holder that died between the mkdir and the
# write, and its age tells the two apart.
#
# The command, not the word: `*aif*` read a reused pid held by any program
# with aif in its command line as a live worker — and the shift opens just
# such programs, `claude '/aif-review <ID>'` sessions, and is one itself, so a
# dead worker's lock would have held its card for the rest of the night
# (docs/DEFECTS.md 14.5). The glob is matched unquoted — a pattern, its `\ `
# an escaped space, which bash 3.2 honours in a pattern held in a variable.
#
# And not a process that started after the lock was signed: a holder signs
# its lock once it runs, so a pid handed out again since — to another `aif
# work`, a loop's worker on another card most likely, which the command
# matches — is not the holder, however its command reads (docs/DEFECTS.md
# 14.5). Its start is `ps -o etime` back from now, the kernel's own count
# (docs/FINDINGS.md #29), against the signature's `started_at`; two seconds of
# slack for the two clocks' whole seconds. A lock signed without the field is
# read as before.
_aif_work_lock_live_as() {
  local pid cmd glob="$2" signed el
  pid="$(_aif_work_lock_pid "$1")"
  if [ -z "$pid" ]; then
    [ -n "$(find "$1" -maxdepth 0 -mmin -1 2>/dev/null)" ]
    return
  fi
  kill -0 "$pid" 2>/dev/null || return 1
  # Held, then matched: `ps | grep -q` under pipefail is FINDINGS #19.
  cmd="$(ps -o command= -p "$pid" 2>/dev/null)" || return 1
  # shellcheck disable=SC2254  # unquoted on purpose: the glob is the pattern
  case "$cmd" in
    $glob) ;;
    *) return 1 ;;
  esac
  signed="$(jq -r '(.started_at // empty) | fromdateiso8601? // empty' "$1/owner.json" 2>/dev/null)" || signed=""
  case "$signed" in
    '' | *[!0-9]*) return 0 ;;
  esac
  # [[dd-]hh:]mm:ss, as BSD and procps both print it.
  el="$(ps -o etime= -p "$pid" 2>/dev/null | awk -F '[-:]' '{ n = NF; s = $n + 60 * $(n - 1)
      if (n >= 3) s += 3600 * $(n - 2); if (n >= 4) s += 86400 * $(n - 3); print s; exit }')" || el=""
  case "$el" in
    '' | *[!0-9]*) return 0 ;;
  esac
  [ $(($(date +%s) - el)) -le $((signed + 2)) ]
}

# _aif_work_lock_live <lock-dir> — rc 0 when a worker is behind the run lock:
# an `aif work` process, alive.
_aif_work_lock_live() {
  _aif_work_lock_live_as "$1" '*aif\ work*'
}

# _aif_work_land_live <root> <ticket> — rc 0 when an `aif land` of <ticket>
# runs in this checkout now, AIF_WORK_LANDING its pid: the land's lock
# (aif_land_lock_dir) names the ticket it lands. A land borrows the ticket's
# worktree for its verdict, so a worker on that ticket waits for it to end —
# as the land refuses a ticket a worker is on (lib/cmd_land.sh;
# docs/DEFECTS.md 15.1).
_aif_work_land_live() {
  local lock
  AIF_WORK_LANDING=""
  lock="$(aif_land_lock_dir "$1")"
  [ -d "$lock" ] || return 1
  [ "$(jq -r '.ticket // empty' "$lock/owner.json" 2>/dev/null)" = "$2" ] || return 1
  _aif_work_lock_live_as "$lock" '*aif\ land*' || return 1
  AIF_WORK_LANDING="$(_aif_work_lock_pid "$lock")"
}

# _aif_work_lock_take <lock-dir> <glob> [<before-takeover>] — take one of the
# three locks — a run's (aif_run_lock_dir), the loop's, the shift's — or say
# why not. rc 0 taken: AIF_LOCK_DEAD is the gone holder's pid when the lock
# was taken over (`?` for one it never signed), else empty · 1 held, by a live
# holder: AIF_LOCK_HELD says by what · 2 another taker took it, or is taking
# it over, just now · 3 <before-takeover> refused, with AIF_LOCK_HELD.
#
# A free lock is a mkdir, atomic on every filesystem. A held one whose holder
# is gone (_aif_work_lock_live_as) is taken over, and that used to be two
# steps, `rm -rf` then `mkdir`: two runs that found the same dead lock in the
# same instant both removed it and both made it again, and the second believed
# it held a lock the first was already working under — written down in each
# lock's comment instead of fixed, three times over (docs/DEFECTS.md 14.5).
# The order now makes one taker win and every other one know it lost:
#
#   1. the mark: `mkdir <lock>/takeover` inside the dead lock's own directory,
#      which only one taker gets. A lock replaced meanwhile by a fresh one
#      takes the mark into the fresh one, and step 2 lets it go again;
#   2. under the mark, the lock read again: still signed by the pid read as
#      gone, and still dead — else someone took it over first;
#   3. the dead lock moved aside (`mv`, a rename, atomic), and the copy
#      checked to be the one read as dead and to carry this taker's mark —
#      else a --stop or a loop's tell removed it under the mark and the path
#      held another, which is put back while the path is free;
#   4. the `mkdir` again: a fresh taker that came in between steps 3 and 4
#      wins it, and this one refuses — exactly one holds the lock either way;
#   5. the copy removed.
#
# The move first and the check after it would move a fresh lock aside too: a
# second taker whose look came after the first one's mkdir renames the new
# lock and only then finds a pid that is not the dead one, and the winner
# works on under a path that is gone — 6 or 7 of 40 races, as `rm -rf` then
# `mkdir` lost 5 to 10; with the mark, none (docs/FINDINGS.md #29; check-work
# scenario 53 races two takers). A taker that died holding the mark leaves it
# in a dead lock: a mark two minutes old is nobody's (find's -mmin +1 on
# macOS: two minutes and more, #29).
#
# <before-takeover> <lock-dir> <dead-pid> runs once the lock is known dead and
# before the mark: the run lock stops what its dead worker left running there
# (_aif_work_lock_orphans), and a takeover with something still running is no
# takeover — the dead lock stays, and says what it left.
_aif_work_lock_take() {
  local lock="$1" glob="$2" hook="${3:-}" pid mark aside
  AIF_LOCK_HELD=""
  AIF_LOCK_DEAD=""
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  mkdir "$lock" 2>/dev/null && return 0
  if _aif_work_lock_live_as "$lock" "$glob"; then
    AIF_LOCK_HELD="$(jq -r '"pid " + (.pid | tostring) + ", since " + .started_at' "$lock/owner.json" 2>/dev/null)" || AIF_LOCK_HELD=""
    [ -n "$AIF_LOCK_HELD" ] || AIF_LOCK_HELD="its lock was taken a moment ago"
    return 1
  fi
  # Released between the mkdir and the look, by a holder that was alive: free.
  if [ ! -d "$lock" ]; then
    mkdir "$lock" 2>/dev/null && return 0
    AIF_LOCK_HELD="another took it just now"
    return 2
  fi
  pid="$(_aif_work_lock_pid "$lock")" || pid=""
  if [ -n "$hook" ] && ! "$hook" "$lock" "$pid"; then
    return 3
  fi
  mark="$lock/takeover"
  if ! mkdir "$mark" 2>/dev/null; then
    if [ -d "$mark" ] && [ -n "$(find "$mark" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rmdir "$mark" 2>/dev/null || true
    fi
    if ! mkdir "$mark" 2>/dev/null; then
      AIF_LOCK_HELD="another is taking it over just now"
      return 2
    fi
  fi
  if [ "$(_aif_work_lock_pid "$lock")" != "$pid" ] || _aif_work_lock_live_as "$lock" "$glob"; then
    rmdir "$mark" 2>/dev/null || true
    AIF_LOCK_HELD="another took it just now"
    return 2
  fi
  aside="$(dirname "$lock")/.${lock##*/}.dead.$$"
  rm -rf "${aside:?}" 2>/dev/null || true
  if ! mv "$lock" "$aside" 2>/dev/null; then
    AIF_LOCK_HELD="another took it just now"
    return 2
  fi
  if [ ! -d "$aside/takeover" ] || [ "$(_aif_work_lock_pid "$aside")" != "$pid" ]; then
    rmdir "$aside/takeover" 2>/dev/null || true
    [ -e "$lock" ] || mv "$aside" "$lock" 2>/dev/null || true
    AIF_LOCK_HELD="another took it just now"
    return 2
  fi
  if ! mkdir "$lock" 2>/dev/null; then
    rm -rf "${aside:?}" 2>/dev/null || true
    AIF_LOCK_HELD="another took it just now"
    return 2
  fi
  rm -rf "${aside:?}" 2>/dev/null || true
  AIF_LOCK_DEAD="${pid:-?}"
  return 0
}

# _aif_work_lock <root> <ticket> — take the run lock for <ticket>, or say who
# holds it. rc 0 taken, AIF_WORK_LOCK names it, and AIF_WORK_TOOK_OVER the
# dead worker's pid when it was taken over · 1 held, AIF_WORK_LOCK_HELD says
# by what · 3 its worker is gone and what it started still runs, named in
# AIF_WORK_LOCK_HELD: no takeover.
#
# Nothing else stops a second `aif work` on the same ticket: it reuses the
# worktree, resumes the same run record, and dispatches into the tree the
# first one is dispatching into. The board cannot say it either — the card
# moves a moment AFTER this, and on a shared board it says nothing about which
# machine took it.
#
# A lock whose worker is gone is taken over (_aif_work_lock_take), once what
# that worker left running is stopped (_aif_work_lock_orphans). The owner
# records the worker's process group beside its pid: a station is in it, and
# so is anything the station started that left the worktree, and a takeover
# reads it to tell an orphan from a free tree (docs/DEFECTS.md 14.1). `ps` is
# asked for it once, here.
_aif_work_lock() {
  local root="$1" ticket="$2" lock rc=0 pgid
  AIF_WORK_LOCK_HELD=""
  AIF_WORK_TOOK_OVER=""
  lock="$(aif_run_lock_dir "$root" "$ticket")"
  AIF_WORK_LOCKING_MAIN="$(aif_main_root "$root")"
  AIF_WORK_LOCKING_ID="$ticket"
  _aif_work_lock_take "$lock" '*aif\ work*' _aif_work_lock_orphans || rc=$?
  case "$rc" in
    0) ;;
    3)
      AIF_WORK_LOCK_HELD="$AIF_LOCK_HELD"
      return 3
      ;;
    *)
      AIF_WORK_LOCK_HELD="$AIF_LOCK_HELD"
      return 1
      ;;
  esac
  if [ -n "$AIF_LOCK_DEAD" ]; then
    AIF_WORK_TOOK_OVER="$AIF_LOCK_DEAD"
    _aif_work_say "lock" "$ticket — the worker that held it (pid $AIF_LOCK_DEAD) is gone; taken over"
  fi
  pgid="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')" || pgid=""
  case "$pgid" in
    '' | *[!0-9]*) pgid=null ;;
  esac
  jq -n --argjson pid "$$" --argjson pgid "$pgid" --arg t "$ticket" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{ ticket: $t, pid: $pid, pgid: $pgid, started_at: $at }' >"$lock/owner.json.tmp" &&
    mv "$lock/owner.json.tmp" "$lock/owner.json"
  AIF_WORK_LOCK="$lock"
  return 0
}

# _aif_work_lock_orphans <lock-dir> <dead-pid> — before a dead run lock is
# taken over: what its worker left running, stopped. rc 0 nothing of it runs
# now · 1 something still does after the wait, named in AIF_LOCK_HELD.
#
# A worker killed outright runs no handler, and its station goes on writing in
# the worktree; the takeover used to look at nothing but the lock, and resumed
# the run and dispatched a station of its own into that tree beside the orphan
# (docs/DEFECTS.md 14.1). So what `aif work --status` lists for the dead lock
# (_aif_work_status_orphans) is sent a TERM first — the whole group, once,
# when the dead worker led it (pgid = its pid, and that pid gone: the group can
# only be its own), else each process alone, never a group some other program
# leads — and looked for again every second, up to AIF_WORK_TAKEOVER_WAIT
# seconds (30): a process the last look missed, a child a station started
# after it, gets its TERM on the next. Something still there at the end — a
# process that ignores TERM — and there is no takeover: exit 3, the card
# untouched, the dead lock left to say what it left.
#
# Only what is proved the dead run's is signalled: its group, with its leader
# gone, and the station pid it recorded. A process named by its working
# directory alone — inside .aif/worktrees/<ID>, nothing else tying it to the
# run — may be a person's shell, editor or language server opened there,
# and it used to get its TERM with the rest; it is named and never
# signalled, and while it runs there is no takeover (docs/DEFECTS.md 14.1).
# Once nothing but such processes is left, the refusal comes at once: no wait
# makes a process go that nothing asked to.
_aif_work_lock_orphans() {
  local lock="$1" lp="$2" main="${AIF_WORK_LOCKING_MAIN:-}" id="${AIF_WORK_LOCKING_ID:-}"
  local orph n nc rows pid pgid why sent=" " deadline wait_s said=0 led=0 grp ours
  wait_s="${AIF_WORK_TAKEOVER_WAIT:-30}"
  case "$wait_s" in
    '' | *[!0-9]*) wait_s=30 ;;
  esac
  deadline=$((SECONDS + wait_s))
  # The dead worker led the group when the group's id is its pid — and with
  # that pid gone, nobody else can lead it.
  [ -z "$lp" ] || _aif_work_pid_alive "$lp" || led=1
  while :; do
    orph="$(_aif_work_status_orphans "$main" "$id" "$lock")" || orph='[]'
    n="$(printf '%s' "$orph" | jq 'length' 2>/dev/null)" || n=0
    case "$n" in
      '' | *[!0-9]*) n=0 ;;
    esac
    [ "$n" -gt 0 ] || return 0
    rows="$(printf '%s' "$orph" | jq -r '.[] | "\(.pid) \(.pgid) \(.why)"' 2>/dev/null)" || rows=""
    if [ "$said" -eq 0 ]; then
      said=1
      nc="$(printf '%s\n' "$rows" | awk '$3 == "cwd" { c++ } END { print c + 0 }')" || nc=0
      [ "$nc" -ge "$n" ] ||
        _aif_work_say "lock" "$id — the worker that held it (pid ${lp:-?}) is gone, and $((n - nc)) process(es) it started still run — TERM, up to ${wait_s}s, before it is taken over"
      [ "$nc" -eq 0 ] ||
        _aif_work_say "lock" "$id — $nc process(es) in its worktree that nothing but their directory ties to the run: named, never signalled — no takeover while one runs"
    fi
    # Each process once; the group once a look, whenever the look finds a
    # member it had not seen — one a station started after the last look.
    grp=""
    ours=0
    while read -r pid pgid why; do
      [ -n "$pid" ] || continue
      [ "$why" != cwd ] || continue
      ours=1
      case "$sent" in
        *" $pid "*) continue ;;
      esac
      sent="$sent$pid "
      if [ "$led" -eq 1 ] && [ "$pgid" = "$lp" ]; then
        grp="$pgid"
      else
        kill -TERM "$pid" 2>/dev/null || true
      fi
    done <<EOF
$rows
EOF
    [ -z "$grp" ] || kill -TERM -- "-$grp" 2>/dev/null || true
    [ "$ours" -eq 1 ] || break
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 1
  done
  AIF_LOCK_HELD="$(printf '%s' "$orph" | jq -r '[ .[] | "pid \(.pid) (\(.command | .[0:60]))"
    + (if .why == "cwd" then " in its worktree, never signalled: nothing but its directory ties it to the run" else "" end) ]
    | join(", ")' 2>/dev/null)" || AIF_LOCK_HELD=""
  [ -n "$AIF_LOCK_HELD" ] || AIF_LOCK_HELD="$n process(es)"
  return 1
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
  local root="$1" ticket="$2" lock pid who col p t0 now last rc
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
    # will tell its card so. The column alone, never through `show`: its
    # comments read dying (docs/DEFECTS.md 14.7) came back here as no column
    # at all, and the lock went under an In Progress card that was left for
    # the next `aif work` to take as fresh. A board that cannot say where the
    # card is keeps the lock, and this is run again.
    rc=0
    col="$(aif_board_card_column "$root" "$ticket" 2>&1)" || rc=$?
    if [ "$rc" -eq 2 ]; then
      aif_err "the worker on $ticket (pid ${pid:-?}) is gone, but the board could not say where its card is — ${col:-no answer}; the lock is kept: run this again when the board answers (aif board check)"
      return 1
    fi
    [ "$rc" -eq 0 ] || col=""
    # What the gone worker left running is stopped with it, as a takeover
    # stops it (_aif_work_lock_orphans): the lock is what names it, and a
    # lock removed over a live station let the next `aif work` take the
    # ticket as fresh and dispatch into the tree that station still edits
    # (docs/DEFECTS.md 14.1). Something that will not stop keeps the lock.
    AIF_WORK_LOCKING_MAIN="$(aif_main_root "$root")"
    AIF_WORK_LOCKING_ID="$ticket"
    if ! _aif_work_lock_orphans "$lock" "$pid"; then
      aif_err "the worker on $ticket (pid ${pid:-?}) is gone, and what it started still runs: $AIF_LOCK_HELD — the lock is kept and the card untouched; aif work --status $ticket lists it"
      return 1
    fi
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
  col="$(aif_board_card_column "$root" "$ticket" 2>/dev/null)" || col=""
  printf '%sstopped%s %s — the card is in %s\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$ticket" "${col:-an unknown column}"
  return 0
}

# _aif_work_pid_alive <pid> — rc 0 when <pid> is a process that runs: kill -0
# answers, and it is not a zombie its parent has yet to reap. A zombie answers
# kill -0 (probed on macOS: ps says Z, and <defunct> for its command) and runs
# nothing; it still holds its pid and its group's id, so for what it left
# behind it is as gone as a pid nobody holds.
_aif_work_pid_alive() {
  local st
  kill -0 "$1" 2>/dev/null || return 1
  st="$(ps -o stat= -p "$1" 2>/dev/null)" || st=""
  [ -n "$st" ] || return 1
  case "$st" in
    *Z*) return 1 ;;
  esac
  return 0
}

# _aif_work_status_orphans <main> <ticket> <lock-dir> — what the dead worker
# behind <lock-dir> left running, as a JSON array of { pid, pgid, why,
# command }, `why` the rule that named it: group, station or cwd.
#
# A worker killed outright — kill -9, a crash — runs no handler, and the
# station under it goes on writing in the worktree with nobody to judge what
# it writes; the next run used to take the lock over and dispatch into the
# same tree (docs/DEFECTS.md 14.1). The ppid walk of _aif_work_descendants
# finds nothing of it: an orphan is the init process's child now. Three
# things still name it, each tied to THIS clone:
#
#   group    its process group is the one the lock records (owner.json's
#            pgid; its pid for a lock from before the field), and that
#            group's leader is gone — a group's id is not handed out again
#            while it has a member, so with its leader gone the group can only
#            be the dead worker's: the loop starts each worker as a group
#            leader, the station stays in it, and so does a child that left
#            the worktree with no prompt in its argv. A leader alive — a pid
#            reused by some other program, or the script that started the
#            worker without job control — and the group is someone else's,
#            never listed;
#   station  the pid the station wrote into <lock>/station as it started
#            (_aif_work_dispatch), alive and still running a station's
#            command — its argv carries the prompt's opening, `Ticket <ID>. `;
#   cwd      its working directory is inside this clone's worktree for the
#            ticket (`lsof -d cwd`, about 0.6 s for every process on a Mac —
#            probed 2026-10-07, docs/FINDINGS.md #29): what a gate's suite or
#            prepare's install left there when the worker shared its parent's
#            group, and a claude Bash tool's command, which leads a session of
#            its own (#28).
#
# The prompt alone used to be a rule, and a second clone of the project on
# this machine building the same id runs a station with the same argv: its
# live build was listed as this clone's orphan, and a requeue TERMed it
# (docs/DEFECTS.md 15.4). It counts now only for a process whose working
# directory is this clone's — its worktree, or the checkout itself, where a
# --no-worktree run builds. Paths are compared as `pwd -P` and lsof give them.
#
# Never listed: the reader itself — this process, every process above it, and
# every process it started (the `$(…)` this runs in, the ps and the lsof) — a
# zombie, and the lock's own pid, a zombie or someone else's. The table is
# held, then matched (docs/FINDINGS.md #19); a command is cut to 200
# characters, because a station's argv carries its whole system prompt.
_aif_work_status_orphans() {
  local main="$1" id="$2" lock="$3" lp grp sp wt="" cwds rows lsof_bin
  lp="$(_aif_work_lock_pid "$lock")" || lp=""
  grp="$(jq -r '.pgid // empty' "$lock/owner.json" 2>/dev/null)" || grp=""
  [ -n "$grp" ] || grp="$lp"
  sp="$(sed -n 1p "$lock/station" 2>/dev/null)" || sp=""
  case "$lp" in
    *[!0-9]*) lp="" ;;
  esac
  case "$grp" in
    *[!0-9]*) grp="" ;;
  esac
  case "$sp" in
    *[!0-9]*) sp="" ;;
  esac
  [ ! -d "$main/$AIF_WORK_WORKTREES/$id" ] || wt="$(cd "$main/$AIF_WORK_WORKTREES/$id" 2>/dev/null && pwd -P)" || wt=""
  # macOS keeps lsof in /usr/sbin, which a PATH set for a job may leave out;
  # with no lsof at all the cwd rule is silent and the other two still hold.
  cwds=""
  lsof_bin="$(command -v lsof 2>/dev/null)" || lsof_bin=""
  [ -n "$lsof_bin" ] || [ ! -x /usr/sbin/lsof ] || lsof_bin=/usr/sbin/lsof
  if [ -n "$lsof_bin" ]; then
    cwds="$("$lsof_bin" -a -d cwd -Fpn 2>/dev/null | awk '/^p/ { p = substr($0, 2) } /^n/ { print "C\t" p "\t" substr($0, 2) }')" || cwds=""
  fi
  rows="$(ps -A -o pid= -o ppid= -o pgid= -o stat= -o command= 2>/dev/null | awk '{ print "P\t" $0 }')" || rows=""
  # The paths through the environment: awk's -v reads a backslash in a value
  # as an escape.
  printf '%s\n%s\n' "$cwds" "$rows" |
    AIF_ORPHAN_WT="$wt" AIF_ORPHAN_MAIN="$main" awk -F '\t' -v me="$$" -v lp="$lp" -v grp="$grp" \
    -v sp="$sp" -v sig="Ticket $id. " '
    BEGIN { wt = ENVIRON["AIF_ORPHAN_WT"]; main = ENVIRON["AIF_ORPHAN_MAIN"] }
    $1 == "C" { cwd[$2] = $3; next }
    $1 == "P" {
      line = substr($0, 3)
      split(line, f, " ")
      cmd = line
      sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[0-9]+[ \t]+[^ \t]+[ \t]*/, "", cmd)
      n++; P[n] = f[1]; PP[f[1]] = f[2]; G[f[1]] = f[3]; S[f[1]] = f[4]; C[f[1]] = cmd
    }
    END {
      x = me; k = 0
      while (x != "" && x + 0 > 1 && k < 256) { skip[x] = 1; x = PP[x]; k++ }
      for (i = 1; i <= n; i++) {
        p = P[i]; x = PP[p]; k = 0
        while (x != "" && x + 0 > 1 && k < 256) {
          if (x == me) { skip[p] = 1; break }
          x = PP[x]; k++
        }
      }
      gone = 0
      if (grp != "") { gone = 1; if ((grp in S) && S[grp] !~ /Z/) gone = 0 }
      for (i = 1; i <= n; i++) {
        p = P[i]
        if (p == "" || (p in skip) || p == lp || S[p] ~ /Z/) continue
        c = (p in cwd) ? cwd[p] : ""
        inwt = (wt != "" && (c == wt || index(c, wt "/") == 1))
        why = ""
        if (gone && G[p] == grp) why = "group"
        else if (sp != "" && p == sp && index(C[p], sig) > 0) why = "station"
        else if (index(C[p], sig) > 0 && (inwt || (c != "" && c == main))) why = "station"
        else if (inwt) why = "cwd"
        if (why == "") continue
        cm = C[p]; gsub(/\t/, " ", cm)
        printf "%s\t%s\t%s\t%s\n", p, G[p], why, cm
      }
    }' | jq -R -s -c '[ split("\n")[] | select(length > 0) | split("\t")
      | { pid: (.[0] | tonumber), pgid: (.[1] | tonumber), why: .[2], command: ((.[3] // "") | .[0:200]) } ]'
}

# _aif_work_status_json <root> <ticket> [<card-sha>] — everything this machine
# knows of <ticket>'s run, as one JSON object on stdout: its run lock (and what a dead
# worker left running), its worktree, its branch, its run record, its report,
# a blocked: comment kept because the board refused it — and a class, with
# one sentence for a person. rc 0 · 2 a record that is there and cannot be
# read (said on stderr), as `aif board head` says the board.
#
# A pure reader, offline: no board, no profile, no lock taken, no trap. What
# a supervisor needs before it moves a card In Progress that nobody seems to
# be building (`aif start`, docs/AUTOPILOT-RESEARCH.md §6.3, R2–R4): the
# board says where the card is and who claimed it, and only this machine can
# say whether its worker is alive, what it got to, and what it left.
#
# Which run record, in order. The worktree's, when there is a worktree: the
# freshest — a run killed between its report's write and its commit is built
# there and nowhere else — with the branch's beside it, which is what `aif
# land` accepts. Else the branch's alone. Else the main checkout's, and only
# when its worktree field is an absolute path: a --no-worktree run, which
# builds in that checkout. Any other record there is an earlier round's
# merged copy, which a land brought back and the intake calls stale.
#
# The classes, first match: live · built (the branch's record and its report
# say built, and the ticket in the checkout is the one built — on the local
# board; on Trello the card is the ticket, and this reader asks no board: the
# card's hash, when a caller that read the card hands it in, stands for it) ·
# built_uncommitted (the record says built and the rest does not yet: `aif
# work <ID>` resumes at done and finishes it) · interrupted (the lock is
# held and its worker is gone: a record still running, a build of a ticket
# since reworked, or no record at all — it died before its intake) ·
# settled_running (the same with no lock: the worker's handler, or a --stop,
# settled the card on its way out) · stopped · spec · no_record (a worktree or
# branch and no record) · none. stopped and spec read the run's record as it
# stands now, the worktree's — never only the branch's, which may hold the
# verdict of the round before the one now in the worktree.
_aif_work_status_json() {
  local root="$1" id="$2" main lock wt held=false live=false pid="" alive=false
  local owner=null livej=null phase="" stopby="" ack=false orphans='[]' station=""
  local wtx=false brx=false subj="" where="" rec=null brec=null report="" tsha=""
  local bfile bx=false bhead="" bmtime="" f t puh=""
  main="$(aif_main_root "$root")"
  lock="$(aif_run_lock_dir "$root" "$id")"
  if [ -d "$lock" ]; then
    held=true
    ! _aif_work_lock_live "$lock" || live=true
    pid="$(_aif_work_lock_pid "$lock")" || pid=""
    case "$pid" in
      '' | *[!0-9]*) pid="" ;;
    esac
    # Views, both: one that does not parse is a lock with nothing to say.
    t="$(jq -c 'objects' "$lock/owner.json" 2>/dev/null)" || t=""
    [ -z "$t" ] || owner="$t"
    t="$(jq -c 'objects' "$lock/live.json" 2>/dev/null)" || t=""
    [ -z "$t" ] || livej="$t"
    # A worker waiting on the runner's limit says until when, in a time a
    # person reads (docs/DEFECTS.md 13.7); one past it is not waiting.
    t="$(jq -r '.paused_until // empty' "$lock/live.json" 2>/dev/null)" || t=""
    case "$t" in
      '' | *[!0-9]*) ;;
      *) [ "$t" -le "$(date +%s)" ] || puh="$(_aif_work_when "$t")" ;;
    esac
    phase="$(sed -n 1p "$lock/phase" 2>/dev/null)" || phase=""
    [ ! -f "$lock/stop" ] || stopby="$(sed -n 1p "$lock/stop" 2>/dev/null)" || stopby=""
    [ ! -f "$lock/ack" ] || ack=true
    station="$(sed -n 1p "$lock/station" 2>/dev/null)" || station=""
    case "$station" in
      *[!0-9]*) station="" ;;
    esac
    [ -z "$pid" ] || ! _aif_work_pid_alive "$pid" || alive=true
    # A dead lock, signed or not: what its worker left is named by the lock's
    # group and station and by this clone's worktree (docs/DEFECTS.md 14.1).
    if [ "$live" = false ]; then
      orphans="$(_aif_work_status_orphans "$main" "$id" "$lock")" || orphans=""
      [ -n "$orphans" ] || orphans='[]'
    fi
  fi

  wt="$main/$AIF_WORK_WORKTREES/$id"
  [ ! -e "$wt/.git" ] || wtx=true
  if git -C "$main" show-ref --verify --quiet "refs/heads/aif/$id" 2>/dev/null; then
    brx=true
    subj="$(git -C "$main" log -1 --format=%s "refs/heads/aif/$id" 2>/dev/null)" || subj=""
    t="$(git -C "$main" show "refs/heads/aif/$id:$AIF_TASKS_DIR/$id/run.json" 2>/dev/null)" || t=""
    if [ -n "$t" ]; then
      brec="$(printf '%s\n' "$t" | jq -c 'objects' 2>/dev/null)" || brec=""
      if [ -z "$brec" ]; then
        aif_err "the run record of $id on branch aif/$id cannot be read as JSON"
        return 2
      fi
    fi
    report="$(git -C "$main" show "refs/heads/aif/$id:$AIF_TASKS_DIR/$id/report.md" 2>/dev/null | sed -n 1p)" || report=""
  fi
  f="$wt/$AIF_TASKS_DIR/$id/run.json"
  if [ "$wtx" = true ] && [ -f "$f" ]; then
    rec="$(jq -c 'objects' "$f" 2>/dev/null)" || rec=""
    if [ -z "$rec" ]; then
      aif_err "the run record of $id in its worktree cannot be read as JSON: $f"
      return 2
    fi
    where=worktree
  elif [ "$brec" != null ]; then
    rec="$brec"
  else
    f="$main/$AIF_TASKS_DIR/$id/run.json"
    if [ -f "$f" ]; then
      t="$(jq -c 'objects' "$f" 2>/dev/null)" || t=""
      if [ -z "$t" ]; then
        aif_err "the run record of $id in this checkout cannot be read as JSON: $f"
        return 2
      fi
      if printf '%s\n' "$t" | jq -e '(.worktree // "") | startswith("/")' >/dev/null 2>&1; then
        rec="$t"
        where=checkout
        report="$(sed -n 1p "$main/$AIF_TASKS_DIR/$id/report.md" 2>/dev/null)" || report=""
      fi
    fi
  fi
  # Whether the ticket changed since the build, against the checkout's
  # ticket.md — on the local board only. On Trello the card's description IS
  # the ticket (the analyst's skill), each run pulls it into its worktree and
  # hashes that (_aif_work_intake, aif_run_resumable), and the checkout's file
  # may be the analyst's older copy: a person who fixed a criterion on the
  # card in the browser got a build of the new text read as "the build is of
  # the ticket before its rework" — no review offered, a requeue loop that
  # resumes at done, an In Progress card moved to Needs Human with a false
  # blocked: line. A reader with no board cannot read the card, so on Trello
  # the question is left to the next run's intake — unless the caller read
  # the card and hands its hash in (<card-sha>, the description as the pull
  # writes it: aif_board_head_json's card_sha256), as the shift does: then
  # the card is the ticket the run is held against, the local board's rule
  # with the card in the checkout's place (docs/DEFECTS.md 15.12).
  f="$main/$AIF_TASKS_DIR/$id/ticket.md"
  if [ "$(aif_board_kind "$root")" != trello ]; then
    [ ! -f "$f" ] || tsha="$(aif_sha256 "$f")"
  else
    case "${3:-}" in
      '' | *[!0-9a-f]*) ;;
      *) tsha="$3" ;;
    esac
  fi

  # What _aif_work_block keeps when the board refused the blocked: comment.
  # Nothing removes it, so it may be an earlier round's: fresh only when it
  # is no older than this run's start (the lock's, else the record's).
  bfile="$main/.aif/tmp/blocked-$id.md"
  if [ -f "$bfile" ]; then
    bx=true
    bhead="$(sed -n 1p "$bfile" 2>/dev/null)" || bhead=""
    bmtime="$(stat -f %m "$bfile" 2>/dev/null)" || bmtime="$(stat -c %Y "$bfile" 2>/dev/null)" || bmtime=""
    case "$bmtime" in
      '' | *[!0-9]*) bmtime="" ;;
    esac
  fi

  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  jq -n -c --arg t "$id" --arg host "$(aif_host_short)" \
    --argjson held "$held" --argjson live "$live" --arg pid "$pid" --argjson alive "$alive" \
    --argjson owner "$owner" --argjson lj "$livej" --arg phase "$phase" --arg stopby "$stopby" \
    --argjson ack "$ack" --argjson orphans "$orphans" --arg station "$station" \
    --arg wtpath "$wt" --argjson wtx "$wtx" --argjson brx "$brx" --arg subj "$subj" \
    --arg where "$where" --argjson rec "$rec" --argjson brec "$brec" --arg report "$report" --arg tsha "$tsha" \
    --arg bpath "$bfile" --argjson bx "$bx" --arg bhead "$bhead" --arg bmtime "$bmtime" --arg puh "$puh" '
    def n: if . == "" then null else . end;
    def num: if . == null or . == "" then null else (tonumber? // null) end;
    def first_line: if . == null then null else (tostring | split("\n")[0]) end;
    def times($k; $one; $many): if $k == 1 then $one else $many end;
    ($owner // {}) as $o
    | ($lj // {}) as $l
    | $rec as $r
    | ($where | n) as $w
    | ($pid | num) as $p
    | ("aif/" + $t) as $b
    | ($r.status // null) as $st
    | (if $w == "worktree" then ($brec.status // null) else $st end) as $bst
    | (if $w == "worktree" then ($brec.finished_at // null) else ($r.finished_at // null) end) as $bfin
    | ($tsha != "" and $r != null and (($r.ticket_sha256 // "") != $tsha)) as $changed
    | (($phase | n) // $l.phase // null) as $ph
    | (if $ph == "claim" or $ph == "worktree" or $ph == "intake" or $ph == "report" then $ph
       else ($l.stage // $r.stage // $ph // "run") end) as $at
    | (if $l.attempt == null then "" else ", attempt \($l.attempt)" end) as $att
    | ($l.started // (if $r == null then null else (try ($r.started_at | fromdateiso8601) catch null) end)) as $since
    | ($bmtime | num) as $mt
    | ($bx and $mt != null and $since != null and $mt >= $since) as $fresh
    | ($orphans | length) as $k
    | ([ $orphans[] | select(.why == "group") ] | length) as $kg
    | ([ $orphans[] | select(.why == "station") ] | length) as $ks
    | ([ $orphans[] | select(.why == "cwd") ] | length) as $kc
    | (if $k == 0 then "; nothing of it still runs"
       elif $kg == $k then "; \($k) \(times($k; "process"; "processes")) still in its group"
       else "; \($k) \(times($k; "process"; "processes")) still running — "
            + ([ (if $kg > 0 then "\($kg) in its group" else empty end),
                 (if $ks > 0 then "\($ks) running its station" else empty end),
                 (if $kc > 0 then "\($kc) in its worktree" else empty end) ] | join(", ")) end) as $left
    | (if $p == null then "" else " (pid \($p))" end) as $pp
    | (if $live then "live"
       elif $bst == "built" and $report == ("# " + $t + " — built") and ($changed | not) then "built"
       elif $st == "built" and ($changed | not) then "built_uncommitted"
       elif $held and ($r == null or $st == "running" or ($st == "built" and $changed)) then "interrupted"
       elif $r != null and ($st == "running" or ($st == "built" and $changed)) then "settled_running"
       elif $st == "stopped" then "stopped"
       elif $st == "spec" then "spec"
       elif $r == null and ($wtx or $brx) then "no_record"
       else "none" end) as $class
    | (if $class == "live" then
         (if $p == null then "a worker took its lock a moment ago and has not signed it yet"
          else "being built here — its worker\($pp) is at \($at)\($att)"
               + (if $puh == "" then "" else ", paused until \($puh) for the runner'"'"'s usage limit" end) end)
       elif $class == "built" then
         (if $w == "checkout" then "the run built it in this checkout (--no-worktree) — there is no branch \($b) for aif land to take"
          else "the run built it; its report is on branch \($b)" end)
         + (if $held then "; the worker that built it\($pp) is gone and left its lock behind" else "" end)
       elif $class == "built_uncommitted" then
         (if $bst != "built" then "its run says built in the worktree, but not on branch \($b) — aif work \($t) finishes it"
          else "its run says built, but its report does not — aif work \($t) finishes it" end)
       elif $class == "interrupted" then
         (if $p == null then "a worker took its lock and is gone without signing it"
          else "its worker\($pp) is gone" + (if $alive then " (the pid now runs another program)" else "" end) end)
         # A lock with no phase file was not "during its claim" — the phase is
         # written right after the lock, and a worker killed in between left
         # nothing to say where it was (docs/DEFECTS.md 15.9).
         + (if $r == null then
              (if $ph == null then ", its phase unknown" else " during its \($ph)" end) + ", before its intake — no station ran"
            elif $st == "built" then ", and the build on branch \($b) is of the ticket before its rework"
            else " mid-\($at)\($att)" end)
         + (if $p == null and $k == 0 then "" else $left end)
       elif $class == "settled_running" then
         (if $st == "built" then "the build on branch \($b) is of the ticket before its rework, and no worker is on it"
          else "its run stopped mid-\($r.stage // "run"), and its worker settled the card on the way out" end)
         + (if $fresh then "; the blocked: line did not reach the card — it is kept in \($bpath)" else "" end)
       elif $class == "stopped" then "its run stopped: " + (($r.why | first_line) // "at \($r.stage // "run")")
       elif $class == "spec" then "its run stopped on the ticket: " + (($r.why | first_line) // "at \($r.stage // "run")")
       elif $class == "no_record" then
         (if $wtx then "a worktree" else "branch \($b)" end) + ", but no run record — its worker stopped before its intake; nothing was spent"
       else "nothing of it on this machine" end) as $why
    | { ticket: $t, host: $host,
        lock: { held: $held, live: $live, pid: $p, pid_alive: $alive, pgid: ($o.pgid // null),
                station: ($station | num),
                started_at: ($o.started_at // null), started: ($l.started // null),
                phase: $ph, stage: ($l.stage // null), attempt: ($l.attempt // null), last: ($l.last // null),
                paused_until: (if $puh == "" then null else ($l.paused_until // null) end),
                stop_requested_by: ($stopby | n), handler_ran: $ack, orphans: $orphans },
        worktree: { path: $wtpath, exists: $wtx },
        branch: { name: $b, exists: $brx, head_subject: ($subj | n) },
        run: { where: $w, status: $st, stage: ($r.stage // null), started_at: ($r.started_at // null),
               finished_at: ($r.finished_at // null), why_head: ($r.why | first_line),
               ticket_sha256: ($r.ticket_sha256 // null), branch: ($r.branch // null),
               branch_status: $bst, branch_finished_at: $bfin, ticket_changed: $changed,
               takeovers: ($r.takeovers // 0) },
        report: { head: ($report | n) },
        blocked_file: { path: $bpath, exists: $bx, head: ($bhead | n), mtime: $mt, fresh: $fresh },
        class: $class, why: $why }' || {
    aif_err "could not put together what this machine knows of $id (jq)"
    return 2
  }
}

# _aif_work_status <root> <ticket|""> <json 0|1> — `aif work --status`: one
# ticket, or every ticket this machine has a trace of — a run lock, a
# worktree, a branch aif/<ID> — as JSON or one line each: `<ID>  <class> —
# <why>`. rc 0, nothing found included · 2 something there that cannot be
# read.
_aif_work_status() {
  local root="$1" id="$2" json="$3" main ids t obj objs=""
  if [ -n "$id" ]; then
    obj="$(_aif_work_status_json "$root" "$id")" || exit 2
    if [ "$json" -eq 1 ]; then
      printf '%s\n' "$obj" | jq .
    else
      printf '%s\n' "$obj" | jq -r '.ticket + "  " + .class + " — " + .why'
    fi
    return 0
  fi
  main="$(aif_main_root "$root")"
  # Names a path can be built from, and nothing else: a ref aif/x/y is not a
  # ticket of ours. A --no-worktree build leaves no lock, worktree or branch
  # once it ends — its one trace is its record in this checkout, its worktree
  # field the checkout's own absolute path — and it was missing from this
  # list (docs/DEFECTS.md 15.9). A record whose field is relative is a
  # worktree run's copy a land brought back, which the reader passes by too;
  # grep finds the candidates, so a checkout of many tickets costs one jq per
  # --no-worktree record, not one per ticket — and finding none is no
  # failure: under pipefail its exit 1 took every other id with it. (No
  # comment inside the substitution: bash 3.2 reads an apostrophe in a
  # comment there as an open quote, probed.)
  ids="$(
    {
      for t in "$main/.aif/state/runs"/* "$main/$AIF_WORK_WORKTREES"/*; do
        [ ! -d "$t" ] || printf '%s\n' "${t##*/}"
      done
      git -C "$main" for-each-ref --format='%(refname)' refs/heads/aif/ 2>/dev/null | sed 's|^refs/heads/aif/||'
      { grep -l '"worktree": *"/' "$main/$AIF_TASKS_DIR"/*/run.json 2>/dev/null || true; } | while IFS= read -r t; do
        if jq -e '(.worktree // "") | startswith("/")' "$t" >/dev/null 2>&1; then
          t="${t%/run.json}"
          printf '%s\n' "${t##*/}"
        fi
      done
    } | grep -E '^[A-Za-z0-9][A-Za-z0-9._-]*$' | LC_ALL=C sort -u
  )" || ids=""
  for t in $ids; do
    obj="$(_aif_work_status_json "$root" "$t")" || exit 2
    objs="$objs$obj
"
  done
  if [ "$json" -eq 1 ]; then
    printf '%s' "$objs" | jq -s .
  elif [ -z "$objs" ]; then
    printf 'no runs on this machine\n'
  else
    printf '%s' "$objs" | jq -r '.ticket + "  " + .class + " — " + .why'
  fi
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

  # Every station's model, against the profile: an alias the profile does
  # not map — `fable` under glm, which routes the other three — went to the
  # profile's endpoint as it was, and failed there, at the first station
  # that asked for it, a card already taken (docs/DEFECTS.md 14.6). Refused
  # here instead, before the claim, naming the station and what the profile
  # does map — the shift's rule (aif_profile_maps_model), so `default`, the
  # CLI's own, passes where opus and sonnet are both mapped; a station that
  # names no model is dispatched as sonnet, and held to sonnet's mapping.
  # In a subshell: the profile is exported for the stations at the end of
  # this preflight, not before.
  local unmapped
  unmapped="$(aif_profile_export_env && _aif_work_station_models "$root")" || unmapped=""
  if [ -n "$unmapped" ]; then
    aif_err "the profile $profile does not map the model a station asks for — $(printf '%s' "$unmapped" | paste -sd ';' - | sed 's/;/; /g') (it maps $(aif_profile_export_env && aif_profile_mapped_aliases)) — name one of those in the station's model: line under .claude/agents/, or a full model id. Nothing was spent, and its card was not touched"
    exit 3
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
  local wt branch on marker installed=1
  wt="$root/$AIF_WORK_WORKTREES/$ticket"
  branch="aif/$ticket"

  if [ -e "$wt/.git" ]; then
    # `aif land` borrows this worktree for its verdict — detached at the
    # target's tip, the merge made and judged there — and puts it back on
    # aif/<ID> however it ends; one killed outright left it detached
    # (lib/cmd_land.sh; docs/DEFECTS.md 15.1). Under a live land it is the
    # land's. Under a dead one, or none, it goes back on its branch the way
    # the land puts it back, and that is said: what a dead land installed
    # there is the merge's, so the install marker goes with it unless the
    # land's own marker says it installed nothing. A worktree on another
    # branch is a person's doing, and not undone here.
    on="$(git -C "$wt" symbolic-ref -q HEAD 2>/dev/null)" || on=""
    if [ "$on" != "refs/heads/$branch" ]; then
      [ -z "$on" ] ||
        aif_die "${wt#"$root"/} is on ${on#refs/heads/}, not $branch — check $branch out there (git -C ${wt#"$root"/} checkout $branch), then run this again"
      if _aif_work_land_live "$root" "$ticket"; then
        aif_die "aif land $ticket is landing it right now (pid $AIF_WORK_LANDING) — its worktree is the land's until it ends"
      fi
      marker="$(aif_land_marker_file "$root")"
      if [ "$(aif_land_marker_get "$marker" .ticket)" = "$ticket" ] &&
        [ "$(aif_land_marker_get "$marker" .installed_in_worktree)" != true ]; then
        installed=0
      fi
      aif_land_worktree_back "$wt" "$branch" "$installed" ||
        aif_die "${wt#"$root"/} is off $branch, and it could not be put back there (git -C ${wt#"$root"/} checkout $branch)"
      printf '%s was left detached — a land of %s that stopped; back on %s\n' "${wt#"$root"/}" "$ticket" "$branch" >&2
    fi
    printf '%s' "$wt"
    return 0
  fi

  # shellcheck source=lib/merge.sh
  . "$AIF_ROOT/lib/merge.sh"
  aif_gitignore_ensure "$root" "$AIF_WORK_WORKTREES/" "worker checkouts — one per ticket, disposable"

  mkdir -p "$(dirname "$wt")"
  # Without the project's hooks, as every git call the worker makes on its
  # own behalf from here — the commits on aif/<ID>, the sync's merge and its
  # checkouts: a post-checkout that exits 7 made this exit 7 after the
  # worktree was cut, and the run was refused for the environment
  # (aif_git_own, lib/common.sh; docs/DEFECTS.md 13.11).
  if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
    aif_git_own "$root" worktree add -q "$wt" "$branch" >/dev/null 2>&1 ||
      aif_die "could not check out $branch into $wt"
  else
    aif_git_own "$root" worktree add -q -b "$branch" "$wt" >/dev/null 2>&1 ||
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
        aif_git_own "$wt" add -A -- "$p" >/dev/null 2>&1 || true
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
    aif_git_own "$wt" add -A -- "$p" >/dev/null 2>&1 || true
    r=$((r + 1))
  done <<EOF
$old_paths
EOF
  [ $((n + r)) -gt 0 ] || return 0
  if ! git -C "$wt" diff --cached --quiet 2>/dev/null; then
    aif_git_own "$wt" -c user.email="aif@local" -c user.name="aif" \
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
  # becomes the bytes the run freezes. The local board holds no text — there
  # the developer's checkout is canonical, as the card is on Trello — so the
  # ticket is carried in from tasks/ on the first run, and again on every
  # later run where the checkout's differs from the branch's. The ticket
  # ALONE on those: a copy of the whole directory would write the checkout's
  # stale run.json and plan.md over the branch's, which hold the run
  # (docs/AUTOPILOT-RESEARCH.md §6.11, verification 6). Before this, a branch
  # that already had a ticket never saw a rework — round two resumed at done
  # and the card went to Review with the old build (docs/DEFECTS.md 13.6).
  # aif_run_resumable sees the sha move, and the restart below does the rest.
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
  elif [ "$src" != "$work" ] && [ -f "$src/ticket.md" ]; then
    if [ ! -f "$work/ticket.md" ]; then
      mkdir -p "$work"
      cp -R "$src/." "$work/"
    elif ! cmp -s "$src/ticket.md" "$work/ticket.md"; then
      cp "$src/ticket.md" "$work/ticket.md"
      _aif_work_say "intake" "the ticket changed in the checkout since the last run — carried in"
    fi
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

  local set_version old_base old_status set_was put_back takeovers=0 took=0
  set_version="$(jq -r '.set_version // empty' "$wt/.aif/manifest.json" 2>/dev/null)"
  base="$(git -C "$wt" rev-parse HEAD 2>/dev/null || printf 'none')"
  if [ -f "$(aif_run_path "$work")" ] && aif_run_resumable "$work" "$set_version"; then
    # A resume gives the record fresh caps, by design — and so a ticket whose
    # every worker died the same way, killed outright and its lock taken over
    # by the next one, was resumed for good, each worker's death unseen by the
    # one after it (docs/DEFECTS.md 14.5). The takeovers are counted in the
    # record, which a resume does not reset, and the cap stops the run before
    # the next resume: rc 4, AIF_WORK_TAKEOVERS says how many.
    if [ -n "${AIF_WORK_TOOK_OVER:-}" ]; then
      takeovers="$(aif_run_get "$work" '.takeovers')" || takeovers=0
      case "$takeovers" in
        '' | *[!0-9]*) takeovers=0 ;;
      esac
      if [ "$takeovers" -ge "$AIF_WORK_TAKEOVERS_MAX" ]; then
        AIF_WORK_TAKEOVERS="$takeovers"
        return 4
      fi
      took=1
    fi
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
       | .base = (.base // $base) | .set_version = (.set_version // $sv)
       | .takeovers = ((.takeovers // 0) + $took)' \
      --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg base "$base" --arg sv "$set_version" \
      --argjson took "$took"
    [ "$took" -eq 0 ] ||
      _aif_work_say "resume" "taken over from a worker that died (pid $AIF_WORK_TOOK_OVER) — takeover $((takeovers + 1)) of the $AIF_WORK_TAKEOVERS_MAX a run may have"
    # A plan station resumed is a plan station about to read the repository,
    # and a plan that stopped — on a spec stop, mostly — left its contract on
    # the floor: skeletons and edits nothing committed. Read as the repository,
    # they would become the next plan's premises (docs/DEFECTS.md 10.3). The
    # stations after it keep their uncommitted work: a retried station fixes
    # its own.
    if [ "$(aif_run_get "$work" '.stage')" = "plan" ] && [ -n "$(aif_git_own "$wt" status --porcelain 2>/dev/null)" ]; then
      put_back="$(aif_git_own "$wt" status --porcelain 2>/dev/null | grep -vcE " (\.aif/|\.claude/|$AIF_TASKS_DIR/$ticket/)" || true)"
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
        aif_git_own "$wt" add -A >/dev/null 2>&1 || true
        if ! git -C "$wt" diff --cached --quiet 2>/dev/null; then
          aif_git_own "$wt" -c user.email="aif@local" -c user.name="aif" \
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

  aif_git_own "$wt" add -A "$AIF_TASKS_DIR/$ticket" >/dev/null 2>&1 || true
  if ! git -C "$wt" diff --cached --quiet 2>/dev/null; then
    aif_git_own "$wt" -c user.email="aif@local" -c user.name="aif" \
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

# --------------------------------------------------------------- the runner
#
# What the worker does when a station's run did not come to an ok or an
# error of the station's own — the account's usage limit, a runner that did
# not answer (docs/DEFECTS.md 13.7, and 13.8's runner half). Both were billed
# to the station: the gate judged what a refused run left, rejected it, the
# retry met the same refusal at once, and the second identical complaint
# stopped the run — Needs Human, blocked: run — while in a loop every worker in
# flight met the same limit and two in a row stopped the queue for the night;
# a runner that wrote nothing stopped the run as blocked: run, so the loop
# counted it against the cards and never asked the machine again; an envelope
# that was not JSON ended the worker under set -e. The user's call
# (2026-10-02): a limit pauses, it does not stop, and paused time is outside
# the wall clock. The classes are aif_runner_claude_classify's; what each
# does is _aif_work_dispatch's.

# _aif_work_num <value> <default> — <value> when it is whole digits, else
# <default>: what the seams below say.
_aif_work_num() {
  case "$1" in
    '' | *[!0-9]*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

# _aif_work_when <epoch> — a time as a person reads it here: HH:MM when it is
# within the next twenty hours, the day before it when it is further
# (`Thu 09:00`), the date when it is more than six days away and a weekday
# would name two.
_aif_work_when() {
  local e="$1" now d fmt='%H:%M'
  case "$e" in
    '' | *[!0-9]* | 0) printf '?' && return 0 ;;
  esac
  now="$(date +%s)"
  d=$((e - now))
  [ "$d" -le 72000 ] || fmt='%a %H:%M'
  [ "$d" -le 518400 ] || fmt='%Y-%m-%d %H:%M'
  date -r "$e" "+$fmt" 2>/dev/null || date -d "@$e" "+$fmt" 2>/dev/null || printf '%s' "$e"
}

# _aif_work_dur <seconds> — "N min" from a minute on, else "N s".
_aif_work_dur() {
  if [ "$1" -ge 60 ]; then printf '%s min' "$(($1 / 60))"; else printf '%s s' "$1"; fi
}

# _aif_work_limit_label <type> — a limit's name as the CLI says it, into
# AIF_LIMIT_LABEL (a global, so the loop that reads it each second forks
# nothing): the types are the rate_limit_event's rateLimitType
# (docs/FINDINGS.md #30).
_aif_work_limit_label() {
  case "$1" in
    five_hour) AIF_LIMIT_LABEL="the session limit" ;;
    seven_day) AIF_LIMIT_LABEL="the weekly limit" ;;
    seven_day_opus) AIF_LIMIT_LABEL="the weekly Opus limit" ;;
    seven_day_sonnet) AIF_LIMIT_LABEL="the weekly Sonnet limit" ;;
    seven_day_overage_included) AIF_LIMIT_LABEL="the Fable 5 limit" ;;
    overage) AIF_LIMIT_LABEL="the usage credit limit" ;;
    credits_required) AIF_LIMIT_LABEL="no usage credits left" ;;
    '' | -) AIF_LIMIT_LABEL="a limit it did not name" ;;
    *) AIF_LIMIT_LABEL="$1" ;;
  esac
}

# _aif_work_pause_scope <type> — which stations a limit holds, by the model
# they ask for: the weekly Opus limit holds opus stations only — plan and
# tests — and lets implement and the sync's MERGE (sonnet) run; the Sonnet
# and Fable 5 limits the same; every other limit holds every station.
_aif_work_pause_scope() {
  case "$1" in
    seven_day_opus) printf opus ;;
    seven_day_sonnet) printf sonnet ;;
    seven_day_overage_included) printf fable ;;
    *) printf all ;;
  esac
}

# _aif_work_pause_read <file> — the shared pause (aif_pause_file) into
# AIF_PAUSE_UNTIL, _SCOPE, _TYPE, _BY, _AT and _WHY; rc 1 when there is none
# or it does not read as one. Builtins only — a test, a read, a case — so the
# loop can look every second and open no window a Ctrl-C can be lost in
# (docs/DEFECTS.md 11.1).
_aif_work_pause_read() {
  local u="" s="" t="" b="" a="" w=""
  AIF_PAUSE_UNTIL="" AIF_PAUSE_SCOPE="" AIF_PAUSE_TYPE="" AIF_PAUSE_BY="" AIF_PAUSE_AT="" AIF_PAUSE_WHY=""
  [ -f "$1" ] || return 1
  { IFS=' ' read -r u s t b a w <"$1"; } 2>/dev/null || true
  case "$u" in
    '' | *[!0-9]*) return 1 ;;
  esac
  case "$a" in
    '' | *[!0-9]*) return 1 ;;
  esac
  case "$s" in
    all | opus | sonnet | fable) ;;
    *) return 1 ;;
  esac
  AIF_PAUSE_UNTIL="$u" AIF_PAUSE_SCOPE="$s" AIF_PAUSE_TYPE="$t" AIF_PAUSE_BY="$b" AIF_PAUSE_AT="$a" AIF_PAUSE_WHY="$w"
  return 0
}

# _aif_work_pause_state <now> — what the pause last read means at <now>, into
# AIF_PAUSE_STATE: paused (it resets within AIF_PAUSE_MAX_SECS, twelve hours —
# any five-hour window, and a weekly reset that falls in the night), held (it
# names no reset and was written within AIF_PAUSE_NORESET_SECS, an hour, or
# its reset is further than a run waits) or none (none read, or stale: a
# pause expires by itself). Plain arithmetic.
_aif_work_pause_state() {
  local now="$1" max="${AIF_PAUSE_MAX_SECS:-}" noreset="${AIF_PAUSE_NORESET_SECS:-}"
  AIF_PAUSE_STATE=none
  [ -n "$AIF_PAUSE_UNTIL" ] || return 0
  # The seams read here with a case, not through _aif_work_num: the loop
  # asks this every second, and a `$(…)` is a fork.
  case "$max" in
    '' | *[!0-9]*) max=43200 ;;
  esac
  case "$noreset" in
    '' | *[!0-9]*) noreset=3600 ;;
  esac
  if [ "$AIF_PAUSE_UNTIL" -eq 0 ]; then
    [ "$now" -ge $((AIF_PAUSE_AT + noreset)) ] || AIF_PAUSE_STATE=held
  elif [ "$AIF_PAUSE_UNTIL" -gt $((now + max)) ]; then
    AIF_PAUSE_STATE=held
  elif [ "$now" -lt "$AIF_PAUSE_UNTIL" ]; then
    AIF_PAUSE_STATE=paused
  fi
  return 0
}

# _aif_work_pause_covers <alias> <resolved> — rc 0 when the pause last read
# holds a station that asks for <alias>, which the profile maps to <resolved>:
# scope all, or its model's word in either.
_aif_work_pause_covers() {
  [ "$AIF_PAUSE_SCOPE" != all ] || return 0
  case " $1 $2 " in
    *"$AIF_PAUSE_SCOPE"*) return 0 ;;
  esac
  return 1
}

# _aif_work_pause_write <until|0> <type> <ticket> <why> — the shared pause,
# for every worker, the loop and the shift on this checkout: written to a
# temp name and moved. A new pause replaces the one there when its scope is
# the same or it holds all; one for one model never replaces one in force for
# another, or for all — rc 1 then, and when it could not be written: the
# worker that met the limit waits on its own deadline (AIF_WORK_PAUSE_OWN).
_aif_work_pause_write() {
  local until="$1" type="${2:--}" by="${3:--}" why f scope now tmp
  why="$(printf '%s' "$4" | tr '\t\n\r' '   ' | cut -c1-300)"
  f="$(aif_pause_file "$AIF_WORK_ROOT")"
  scope="$(_aif_work_pause_scope "$type")"
  now="$(date +%s)"
  if _aif_work_pause_read "$f"; then
    _aif_work_pause_state "$now"
    if [ "$AIF_PAUSE_STATE" != none ] && [ "$scope" != all ] && [ "$AIF_PAUSE_SCOPE" != "$scope" ]; then
      return 1
    fi
  fi
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  tmp="$f.tmp.$$"
  if ! { printf '%s %s %s %s %s %s\n' "$until" "$scope" "$type" "$by" "$now" "$why" >"$tmp" &&
    mv -f "$tmp" "$f"; } 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  return 0
}

# _aif_work_pause_json <root> — the shared pause as `aif start` and `aif work
# --status` read it: `{ state, until, until_hhmm, scope, type, label, by,
# at, why }`, or null when none holds — the oracle reads no clock
# (lib/start.jq), so the state and the time a person reads are said here.
_aif_work_pause_json() {
  local f now hhmm=""
  f="$(aif_pause_file "$1")"
  if ! _aif_work_pause_read "$f"; then
    printf 'null'
    return 0
  fi
  now="$(date +%s)"
  _aif_work_pause_state "$now"
  if [ "$AIF_PAUSE_STATE" = none ]; then
    printf 'null'
    return 0
  fi
  [ "$AIF_PAUSE_UNTIL" -eq 0 ] || hhmm="$(_aif_work_when "$AIF_PAUSE_UNTIL")"
  _aif_work_limit_label "$AIF_PAUSE_TYPE"
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  jq -cn --arg state "$AIF_PAUSE_STATE" --argjson until "$AIF_PAUSE_UNTIL" --arg hhmm "$hhmm" \
    --arg scope "$AIF_PAUSE_SCOPE" --arg type "$AIF_PAUSE_TYPE" --arg label "$AIF_LIMIT_LABEL" \
    --arg by "$AIF_PAUSE_BY" --argjson at "$AIF_PAUSE_AT" --arg why "$AIF_PAUSE_WHY" '
    { state: $state, until: (if $until == 0 then null else $until end),
      until_hhmm: (if $hhmm == "" then null else $hhmm end), scope: $scope,
      type: (if $type == "-" then null else $type end), label: $label,
      by: (if $by == "-" then null else $by end), at: $at, why: $why }' 2>/dev/null || printf 'null'
}

# _aif_work_sleep — one second, spent in the `wait` builtin on a `sleep 1` put
# in the background: a TERM, a Ctrl-C or a hang-up that comes while the
# worker waits on the runner runs its handler at once, where a foreground
# `sleep` loses one that lands as it ends (docs/DEFECTS.md 11.1;
# docs/FINDINGS.md #33). A sleep an interrupt leaves is ended here.
_aif_work_sleep() {
  local t rc=0
  sleep 1 &
  t=$!
  wait "$t" 2>/dev/null || rc=$?
  [ "$rc" -le 128 ] || kill -TERM "$t" 2>/dev/null || true
  return 0
}

# _aif_work_beat_due — the claim's heartbeat (_aif_work_heartbeat), once a
# minute while the worker waits on the runner (AIF_WORK_BEAT_SECS, the
# harness's): a worker paused through a five-hour window that beat only at a
# dispatch's start would read, to a shift on another machine, as a worker
# gone once its claim was silent past the wall clock and ten minutes more
# (docs/DEFECTS.md 14.4, 13.7).
_aif_work_beat_due() {
  local every
  every="$(_aif_work_num "${AIF_WORK_BEAT_SECS:-}" 60)"
  [ $((SECONDS - ${AIF_WORK_BEAT_AT:-0})) -ge "$every" ] || return 0
  AIF_WORK_BEAT_AT="$SECONDS"
  _aif_work_heartbeat
}

# _aif_work_pause_wait <alias> <resolved> <station> — before every try of a
# dispatch: while a pause holds this station (the shared one, paused, of a
# scope that covers its model — or this worker's own deadline when the shared
# one could not say it), wait for it, a second at a time, the file read again
# each second: `rm .aif/state/pause` lifts it by hand, and the worker that met
# the limit lifts nothing. The seconds go to AIF_WORK_PAUSED_SECS, outside the
# wall clock, and into AIF_WORK_PAUSE_WAITED for the wait just made. Said
# once per reset; the dashboard's box shows it (live.json); a handler that runs
# meanwhile says it on the card (AIF_WORK_WAITING). A held pause — no reset, or
# one past the horizon — is not waited on: the worker meets the limit itself on
# its next try, one refused call, and stops on the environment.
_aif_work_pause_wait() {
  local alias="$1" resolved="$2" station="$3" f now until said="" t0 waited hhmm e0
  f="$(aif_pause_file "$AIF_WORK_ROOT")"
  AIF_WORK_PAUSE_WAITED=0
  t0="$SECONDS"
  # The clock from one `date` and the shell's own count after it: nothing
  # forked each second for a signal to kill (docs/FINDINGS.md #33).
  e0=$(($(date +%s) - SECONDS))
  while :; do
    now=$((e0 + SECONDS))
    until=""
    if _aif_work_pause_read "$f"; then
      _aif_work_pause_state "$now"
      if [ "$AIF_PAUSE_STATE" = paused ] && _aif_work_pause_covers "$alias" "$resolved"; then
        until="$AIF_PAUSE_UNTIL"
      fi
    fi
    if [ -n "${AIF_WORK_PAUSE_OWN:-}" ] && [ "$AIF_WORK_PAUSE_OWN" -gt "$now" ]; then
      [ -n "$until" ] && [ "$until" -ge "$AIF_WORK_PAUSE_OWN" ] || until="$AIF_WORK_PAUSE_OWN"
      AIF_PAUSE_TYPE="${AIF_WORK_PAUSE_OWN_TYPE:-$AIF_PAUSE_TYPE}"
    fi
    [ -n "$until" ] || break
    if [ "$until" != "$said" ]; then
      said="$until"
      hhmm="$(_aif_work_when "$until")"
      _aif_work_limit_label "$AIF_PAUSE_TYPE"
      AIF_WORK_WAITING="paused for the runner's usage limit until $hhmm"
      _aif_work_say "runner" "paused until $hhmm — $AIF_LIMIT_LABEL${AIF_PAUSE_BY:+, met by $AIF_PAUSE_BY}; $station waits for it, outside the wall clock (rm .aif/state/pause lifts it)"
      # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
      _aif_work_live '.paused_until = $u | .paused_type = $t | .last = $l | .last_tone = "retry"' \
        --argjson u "$until" --arg t "$AIF_PAUSE_TYPE" --arg l "paused until $hhmm — $AIF_LIMIT_LABEL"
    fi
    _aif_work_beat_due
    _aif_work_sleep
  done
  waited=$((SECONDS - t0))
  AIF_WORK_WAITING=""
  [ -n "$said" ] || return 0
  AIF_WORK_PAUSE_WAITED="$waited"
  AIF_WORK_PAUSED_SECS=$((${AIF_WORK_PAUSED_SECS:-0} + waited))
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  _aif_work_live 'del(.paused_until, .paused_type) | .stage_started = $t | .last = $l' \
    --argjson t "$(date +%s)" --arg l "$station dispatched again after the pause"
  _aif_work_say "runner" "paused $(_aif_work_dur "$waited") — $station dispatched again, the same attempt"
  return 0
}

# _aif_work_backoff_wait <seconds> — a runner that did not answer is asked
# again after this long: a second at a time, outside the wall clock (the
# environment's time, bounded per dispatch by AIF_TRANSIENT_BACKOFF), the
# claim beating meanwhile.
_aif_work_backoff_wait() {
  local n="$1" t0
  t0="$SECONDS"
  while [ $((SECONDS - t0)) -lt "$n" ]; do
    _aif_work_beat_due
    _aif_work_sleep
  done
  AIF_WORK_PAUSED_SECS=$((${AIF_WORK_PAUSED_SECS:-0} + SECONDS - t0))
}

# _aif_work_wait_record <station> <class> <type> <reset> <until> <waited>
# <why> <facts-file> — one try that was not the station's own, into the run's
# record (`.runner_waits`, AIF_WORK_WORK — never a repair's copy): the class
# and the limit or the error that said it, what the stream said of it (the
# last rate_limit_info, the API error's kind — what will verify the
# classifier on the first real limit), the turns and tokens it spent, how
# long the worker waited. The report's "Waited on the runner" reads it.
_aif_work_wait_record() {
  [ -n "${AIF_WORK_WORK:-}" ] && [ -f "$(aif_run_path "$AIF_WORK_WORK")" ] || return 0
  local facts="$8"
  [ -s "$facts" ] || facts=/dev/null
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  aif_run_update "$AIF_WORK_WORK" '
    ($f[0] // {}) as $x
    | .runner_waits = ((.runner_waits // []) + [ {
        stage: $s, via: $via, attempt: ($att | tonumber? // $att), class: $c, type: $t,
        reset: ($r | tonumber? // 0), until: ($u | tonumber? // 0), waited_s: ($w | tonumber? // 0),
        turns: ($x.num_turns // 0), output_tokens: ($x.output_tokens // 0), why: $why,
        rate_limit: ($x.rate_limit // null), api_error: ($x.api_error // null), at: $at } ])' \
    --arg s "$1" --arg via "${AIF_WORK_DISPATCH_VIA:-stage}" --arg att "${AIF_WORK_DISPATCH_ATTEMPT:-}" \
    --arg c "$2" --arg t "$3" --arg r "$4" --arg u "$5" --arg w "$6" --arg why "$7" \
    --slurpfile f "$facts" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" 2>/dev/null || true
}

# _aif_work_wait_waited <seconds> — the last wait recorded, its seconds now
# known: a limit's pause is waited at the top of the next try.
_aif_work_wait_waited() {
  [ -n "${AIF_WORK_WORK:-}" ] && [ -f "$(aif_run_path "$AIF_WORK_WORK")" ] || return 0
  # shellcheck disable=SC2016  # jq's variable, bound by --argjson
  aif_run_update "$AIF_WORK_WORK" '
    ((.runner_waits // []) | length) as $n
    | if $n == 0 then . else .runner_waits[$n - 1].waited_s = $w end' --argjson w "$1" 2>/dev/null || true
}

# _aif_work_clock_past — rc 0 when this run is past its wall clock, the
# seconds it waited on the runner left out: a limit's wait is the user's
# decision and a backoff the environment's time (docs/DEFECTS.md 13.7). ONE
# question, asked before every dispatch — the stage loop's, a repair's (up to
# four), a sync's (up to three) — where it used to be asked at the top of the
# stage loop alone, and a repair or a sync ran on past it.
_aif_work_clock_past() {
  [ -n "${AIF_WORK_CLOCK_START:-}" ] && [ -n "${AIF_WORK_CLOCK_MAX:-}" ] || return 1
  [ $(($(date +%s) - AIF_WORK_CLOCK_START - ${AIF_WORK_PAUSED_SECS:-0})) -gt "$AIF_WORK_CLOCK_MAX" ]
}

# _aif_work_clock_why — why a run past its wall clock stopped, on the line
# the shift reads as a cap (lib/start.jq R17: `wall clock:`).
_aif_work_clock_why() {
  local cap waited=""
  if [ -n "${AIF_WORK_MAX_SECS_SET:-}" ]; then cap="${AIF_WORK_CLOCK_MAX} seconds"; else cap="$((AIF_WORK_CLOCK_MAX / 60)) minutes"; fi
  [ "${AIF_WORK_PAUSED_SECS:-0}" -eq 0 ] || waited=" ($(_aif_work_dur "$AIF_WORK_PAUSED_SECS") waiting on the runner, outside it)"
  printf 'wall clock: past %s%s. What was accepted is committed on the branch; nothing after it is.' "$cap" "$waited"
}

# _aif_work_cut_text <what ended it> <turns|""> — what the same attempt is told
# when it is dispatched again after a try the runner cut off: that it ran,
# that nothing judged it, that its work is in the tree. Prefixed with its own
# blank line, for the prompt's end. Never the words the harness's stations
# key on: "was REJECTED", "MERGE", a line that starts "REPAIR".
_aif_work_cut_text() {
  local how="and left no account of how far it got"
  [ -z "$2" ] || how="after $2 turn(s)"
  printf '\n\nYour previous run of this same attempt ended early — %s — %s; no gate has judged it. What it wrote is in the tree as it left it: read it before you write, and finish the work.' "$1" "$how"
}

# _aif_work_backoff_list — AIF_TRANSIENT_BACKOFF's seconds, "60 300 900"
# unless every word of it is digits.
_aif_work_backoff_list() {
  local w
  for w in ${AIF_TRANSIENT_BACKOFF:-60 300 900}; do
    case "$w" in
      *[!0-9]*)
        printf '60 300 900'
        return 0
        ;;
    esac
  done
  printf '%s' "${AIF_TRANSIENT_BACKOFF:-60 300 900}"
}

# _aif_work_station_models <root> — the station a run may dispatch whose model
# the loaded profile does not map, one `<agent> asks for <model>` a line (the
# CLI's default when it names none: what the dispatch sends then is sonnet).
# Run once the profile is exported (aif_profile_maps_model reads what that
# exported).
_aif_work_station_models() {
  local f agent m
  for f in "$1"/.claude/agents/aif-*.md; do
    [ -f "$f" ] || continue
    agent="${f##*/}"
    agent="${agent%.md}"
    m="$(_aif_work_frontmatter "$1" "$agent" model)" || m=""
    [ -n "$m" ] || m=sonnet
    aif_profile_maps_model "$m" || printf '%s asks for %s\n' "$agent" "$m"
  done
  return 0
}

# _aif_work_dispatch <wt> <ticket> <station> <agent> <complaint> <budget-left>
#                    <envelope-out>
#
# One station run. Writes the envelope to <envelope-out>, stages the cost row
# for `aif _gate` to fold, and returns 0 when the station's run was its own —
# ok, or an error of the station's — the outcome of the station is read from
# the envelope by the caller, because a failed station is a recorded attempt,
# not an aborted one. What the runner did instead — a usage limit, no answer
# — is this function's, below: 3 the environment, 4 the wall clock.
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
  # Every dispatch — the stage loop's, a repair's, a sync's — says on the card
  # that this worker lives (docs/DEFECTS.md 14.4).
  _aif_work_heartbeat

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

  # The guard hook reads these: a station may write only what its station
  # owns, and the ticket names the plan whose files.tests says what a test is
  # — a manual mock or a fixture the plan declares included (sets/claude/
  # hooks/guard.sh; docs/DEFECTS.md 13.10).
  export AIF_STATION="$station"
  export AIF_TICKET="$ticket"

  # A pause the runner's limit holds this station's model under — met by any
  # worker of this checkout (_aif_work_pause_write) — is waited out before
  # the station is said to start, and before each try after it (below).
  AIF_WORK_WAIT_PENDING=0
  _aif_work_pause_wait "$model" "$resolved" "$station"
  _aif_work_say "station" "$station · $agent · $model · ≤$max_turns turns$knows"
  # THIS aif first on the station's PATH: `aif _verify` inside the tests
  # station must reach the aif that dispatched it, not whatever Homebrew
  # installed beside it.
  local path_was="$PATH"
  export PATH="$AIF_ROOT/bin:$PATH"
  # The station's own pid, in the run lock while it runs: written by the
  # station's process itself, a `/bin/sh` that execs the station in its place
  # (the runner's, and the seam's here), so the station stays the worker's
  # foreground child, in the worker's group, where a Ctrl-C and a --stop
  # reach it as before — never a background `&`, which a non-interactive bash
  # starts with SIGINT ignored (docs/FINDINGS.md #23; the wrapper probed in
  # #29: the file holds the station's pid, its pgid is the worker's, a group
  # INT and a TERM to the worker's children each ended it at once). A worker
  # killed outright leaves the file, and the takeover reads it: the station
  # of a worker a script started without job control is in no group of its
  # own to find it by (docs/DEFECTS.md 14.1). Gone once the dispatch ends.
  local pidfile=""
  [ -z "${AIF_WORK_LOCK:-}" ] || [ ! -d "$AIF_WORK_LOCK" ] || pidfile="$AIF_WORK_LOCK/station"

  # The station runs until its run is the station's own — ok, or an error the
  # gate then judges by what it left — and every other end of a try is the
  # runner's (aif_runner_claude_classify), never billed to the station: the
  # same attempt dispatched again, uncounted by the stage loop, which counted
  # it once (docs/DEFECTS.md 13.7).
  #
  #   limit      the account's usage limit. A reset within AIF_PAUSE_MAX_SECS
  #              (12 h): the shared pause, written for every worker, the loop
  #              and the shift, and waited out at the top of the next try,
  #              outside the wall clock. No reset named, or one further off —
  #              a weekly reset days away, a credit limit — and the run stops
  #              on the environment naming it, the pause left as a hold the
  #              loop stops on; so does a fourth limit in a row here.
  #   transient  the runner did not answer — no envelope, not JSON, the
  #              throttle, overload, a 5xx: asked again after each of
  #              AIF_TRANSIENT_BACKOFF's seconds (60 300 900), on top of the
  #              CLI's own retries, outside the wall clock; then the
  #              environment. A stream that is not JSON no longer reaches a jq
  #              under set -e.
  #
  # The tree is not put back between tries: a retry already builds on the
  # uncommitted work of the attempt before it, so no commit is "the
  # attempt's base". A try cut off after it worked, or that left no account
  # of itself, is told so — in words the harness's stations key on none of
  # (was REJECTED, MERGE, a line that starts REPAIR). What a swallowed try
  # cost goes to AIF_WORK_DISPATCH_EXTRA for the caller's spend; its tokens
  # are in the run's runner_waits, never in a ledger row.
  #
  # rc 0 the station's own run, its envelope in <envelope-out> · 3 the
  # environment, AIF_WORK_DISPATCH_WHY says it for the card and
  # AIF_WORK_RUNNER_ENV is 1 — the run ends blocked: environment, which the
  # loop takes for the machine (13.8) · 4 the wall clock, asked before every
  # try (_aif_work_clock_past).
  local stream="$out.stream" facts="$out.facts" line cls reset type why tries=0 limits=0
  local delays d ret=0 cut="" now max margin until label when limit_turns t0_disp transients=0
  AIF_WORK_DISPATCH_WHY=""
  AIF_WORK_DISPATCH_EXTRA=0
  AIF_WORK_RUNNER_ENV=0
  AIF_WORK_BEAT_AT="$SECONDS"
  delays=" $(_aif_work_backoff_list) "
  t0_disp="$SECONDS"
  while :; do
    if [ "$tries" -gt 0 ]; then
      _aif_work_pause_wait "$model" "$resolved" "$station"
      [ "${AIF_WORK_WAIT_PENDING:-0}" != 1 ] || _aif_work_wait_waited "$AIF_WORK_PAUSE_WAITED"
      AIF_WORK_WAIT_PENDING=0
    fi
    if _aif_work_clock_past; then
      ret=4
      break
    fi
    tries=$((tries + 1))
    rc=0
    rm -f "$stream" "$facts"
    [ "$tries" -eq 1 ] || _aif_work_beat_due
    if [ -n "${AIF_WORK_STATION_CMD:-}" ]; then
      if [ -n "$pidfile" ]; then
        # shellcheck disable=SC2016  # $$ and "$@" are the wrapper shell's own
        /bin/sh -c 'echo $$ >"$0"; exec "$@"' "$pidfile" \
          "$AIF_WORK_STATION_CMD" "$station" "$ticket" "$wt" "$sys" "$prompt$cut" "$model" \
          "$max_turns" "$budget_left" "$tools" "$stream" "$err" || rc=$?
      else
        "$AIF_WORK_STATION_CMD" "$station" "$ticket" "$wt" "$sys" "$prompt$cut" "$model" \
          "$max_turns" "$budget_left" "$tools" "$stream" "$err" || rc=$?
      fi
    else
      "aif_runner_${AIF_PROFILE_RUNNER}_station" "$wt" "$sys" "$prompt$cut" "$model" \
        "$max_turns" "$budget_left" "$tools" "$stream" "$err" "$pidfile" || rc=$?
    fi
    [ -z "$pidfile" ] || rm -f "$pidfile"
    line="$("aif_runner_${AIF_PROFILE_RUNNER}_classify" "$stream" "$out" "$facts")" || line=""
    cls="" reset=0 type="" why=""
    IFS=$'\t' read -r cls reset type why <<EOF
$line
EOF
    case "$cls" in
      ok | error) break ;;
      limit | transient) ;;
      *) cls=transient type=not-json ;;
    esac
    case "$reset" in
      '' | *[!0-9]*) reset=0 ;;
    esac
    # What the runner itself said on its way out, when the stream says
    # nothing: a CLI that could not start writes only there.
    [ -n "$why" ] || why="$(sed -n '/[^[:space:]]/{p;q;}' "$err" 2>/dev/null | cut -c1-200)" || why=""
    [ ! -s "$out" ] ||
      AIF_WORK_DISPATCH_EXTRA="$(awk -v s="$AIF_WORK_DISPATCH_EXTRA" -v c="$(_aif_work_envelope_cost "$wt" "$out")" 'BEGIN { printf "%.4f", s + c }')"
    limit_turns="$(jq -r '.num_turns // 0' "$facts" 2>/dev/null)" || limit_turns=0
    case "$limit_turns" in
      '' | *[!0-9]*) limit_turns=0 ;;
    esac
    now="$(date +%s)"
    if [ "$cls" = limit ]; then
      limits=$((limits + 1))
      _aif_work_limit_label "$type"
      label="$AIF_LIMIT_LABEL"
      max="$(_aif_work_num "${AIF_PAUSE_MAX_SECS:-}" 43200)"
      margin="$(_aif_work_num "${AIF_PAUSE_MARGIN_SECS:-}" 120)"
      if [ "$reset" -gt 0 ] && [ "$reset" -le $((now + max)) ] && [ "$limits" -lt 4 ]; then
        until=$reset
        [ "$until" -ge "$now" ] || until=$now
        until=$((until + margin))
        AIF_WORK_PAUSE_OWN=""
        if ! _aif_work_pause_write "$until" "$type" "$ticket" "$why"; then
          AIF_WORK_PAUSE_OWN="$until"
          AIF_WORK_PAUSE_OWN_TYPE="$type"
        fi
        _aif_work_wait_record "$station" limit "$type" "$reset" "$until" 0 "$why" "$facts"
        AIF_WORK_WAIT_PENDING=1
        _aif_work_say "runner" "$station — the runner's usage limit ($label): resets $(_aif_work_when "$reset"); the same attempt waits for it, outside the wall clock (attempt uncounted)"
        cut=""
        [ "$limit_turns" -eq 0 ] ||
          cut="$(_aif_work_cut_text "the runner's usage limit" "$limit_turns")"
        continue
      fi
      if [ "$limits" -ge 4 ]; then
        AIF_WORK_DISPATCH_WHY="the runner's usage limit ($label) refused the $station station $limits times in a row, each reset waited out — the environment, not the ticket"
      else
        until=0
        [ "$reset" -eq 0 ] || until=$((reset + margin))
        _aif_work_pause_write "$until" "$type" "$ticket" "$why" || true
        if [ "$reset" -eq 0 ]; then when="no reset named"; else when="resets $(_aif_work_when "$reset")"; fi
        AIF_WORK_DISPATCH_WHY="the runner's usage limit ($label): $when — longer than a run waits${why:+ ($why)}"
      fi
      _aif_work_wait_record "$station" limit "$type" "$reset" "${until:-0}" 0 "$why" "$facts"
      AIF_WORK_RUNNER_ENV=1
      ret=3
      break
    fi
    # transient: the next wait in the list, or the environment. A limit
    # after it is the first in a row again.
    limits=0
    transients=$((transients + 1))
    d="$(printf '%s' "$delays" | awk -v i="$transients" '{ print (i <= NF) ? $i : "" }')"
    if [ -z "$d" ]; then
      AIF_WORK_DISPATCH_WHY="the runner did not answer for the $station station — $type${why:+: $why}, $tries tries over $(_aif_work_dur $((SECONDS - t0_disp))) — the environment, not the ticket"
      _aif_work_wait_record "$station" transient "$type" 0 0 0 "$why" "$facts"
      AIF_WORK_RUNNER_ENV=1
      ret=3
      break
    fi
    _aif_work_say "runner" "$station — $type${why:+: $why}; again in ${d}s (attempt uncounted)"
    AIF_WORK_WAITING="waiting on the runner ($type), again at $(_aif_work_when $((now + d)))"
    _aif_work_backoff_wait "$d"
    AIF_WORK_WAITING=""
    _aif_work_wait_record "$station" transient "$type" 0 0 "$d" "$why" "$facts"
    cut=""
    if [ ! -s "$out" ]; then
      cut="$(_aif_work_cut_text "the runner did not answer" "")"
    elif [ "$limit_turns" -gt 0 ]; then
      cut="$(_aif_work_cut_text "the API did not answer" "$limit_turns")"
    fi
  done
  rm -f "$stream" "$facts"
  export PATH="$path_was"
  unset AIF_STATION AIF_TICKET
  rm -f "$sys"
  if [ "$ret" -ne 0 ]; then
    if [ "$ret" -eq 3 ]; then
      aif_err "$AIF_WORK_DISPATCH_WHY"
    fi
    rm -f "$err"
    return "$ret"
  fi
  rm -f "$err"

  # Stage the cost row for `aif _gate` to fold into the ledger after the gates
  # have run. Written here and folded there for the reason every other piece of
  # this bookkeeping is: the ledger lives under tasks/, scope diffs the working
  # tree, and instrumentation must not perturb what it measures.
  local usage turns cost summary subtype model_ran result
  usage="$("aif_runner_${AIF_PROFILE_RUNNER}_result_usage" "$out")"
  # Guarded, though only an envelope that classified is here now: a jq that
  # cannot read it must not end the worker under set -e (docs/DEFECTS.md 13.7).
  turns="$(jq -r '.num_turns // 0' "$out" 2>/dev/null)" || turns=0
  case "$turns" in
    '' | *[!0-9]*) turns=0 ;;
  esac
  subtype="$("aif_runner_${AIF_PROFILE_RUNNER}_result_subtype" "$out")" || subtype=""
  summary="$(jq -r '(.result // "") | split("\n")[0] | .[0:200]' "$out" 2>/dev/null)" || summary=""
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

# _aif_work_copy_at <wt> <base> <copy> — <copy>, an empty directory, made a copy
# of the worktree as it stood at <base>: every path changed since that commit
# put back, every path added since it removed, what git ignores copied as it
# is — but the installed dependencies, linked. The same copy the gates'
# aif_g_scratch_at makes (which lib/ cannot source), for the same reasons: a
# suite runs against installed dependencies, a node_modules copied once per
# repair beside every other worker's is most of a JavaScript tree
# (docs/DEFECTS.md 13.9), and git is never run inside the copy — a copy of a
# linked worktree carries its .git FILE, and git run there writes the real
# worktree's index (docs/FINDINGS.md #20). AIF_G_COPY_DEPS=1 copies the
# dependencies as before, as it does for the gates: a package that finds the
# project from its own location reads the real tree through a link (#36).
#
# rc 0 · 1 the copy could not be made whole, AIF_WORK_COPY_WHY says why — an
# unreadable file used to be left out in silence (cp -R … || true), and the
# repaired tests were judged in another tree.
_aif_work_copy_at() {
  local wt="$1" base="$2" copy="$3" links="" walk p changed
  AIF_WORK_COPY_WHY=""
  [ "${AIF_G_COPY_DEPS:-0}" = 1 ] || links="$(_aif_work_dep_dirs "$wt")"
  walk="$links"
  [ ! -d "$wt/.aif/worktrees" ] || walk="$walk
.aif/worktrees"
  _aif_work_copy_into "$wt" "$copy" "" "$links" "$walk" || return 1
  changed="$({
    git -C "$wt" -c core.quotePath=false diff --name-only "$base" 2>/dev/null
    git -C "$wt" -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null
  } | sort -u)"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    _aif_work_under "$p" "$links" && continue
    rm -rf "${copy:?}/${p:?}" 2>/dev/null || true
    git -C "$wt" cat-file -e "$base:$p" 2>/dev/null || continue
    if ! mkdir -p "$copy/$(dirname "$p")" 2>/dev/null || ! git -C "$wt" show "$base:$p" >"$copy/$p" 2>/dev/null; then
      AIF_WORK_COPY_WHY="could not put $p back as it was at ${base:0:10}"
      return 1
    fi
  done <<EOF
$changed
EOF
  return 0
}

# _aif_work_dep_dirs <wt> — the installed dependencies a copy links: every
# node_modules (the first one down each branch), .venv or venv at the root,
# each while git ignores it. The gates' aif_g_dep_dirs, kept equal by
# scripts/check-work.sh.
_aif_work_dep_dirs() {
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

# _aif_work_under <path> <dirs> — rc 0 when <path> is one of <dirs> or under one.
_aif_work_under() {
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

# _aif_work_copy_into <src> <dst> <rel> <links> <walk> — the gates'
# _aif_g_copy_into: a directory in <links> linked, one with something of
# <walk> below it entered, .aif/worktrees left behind, every other entry
# `cp -R`, checked. rc 1 with AIF_WORK_COPY_WHY.
_aif_work_copy_into() {
  local src="$1" dst="$2" rel="$3" links="$4" walk="$5" p r d err
  for p in "$src${rel:+/$rel}"/* "$src${rel:+/$rel}"/.[!.]* "$src${rel:+/$rel}"/..?*; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    r="${p#"$src"/}"
    [ "$r" != ".aif/worktrees" ] || continue
    case "
$links
" in
      *"
$r
"*)
        ln -s "$p" "$dst/$r" 2>/dev/null || {
          AIF_WORK_COPY_WHY="could not link $r into the copy"
          return 1
        }
        continue
        ;;
    esac
    case "
$walk" in
      *"
$r/"*)
        mkdir -p "$dst/$r" || return 1
        _aif_work_copy_into "$src" "$dst" "$r" "$links" "$walk" || return 1
        continue
        ;;
    esac
    d="$dst"
    case "$r" in */*) d="$dst/${r%/*}" ;; esac
    if ! err="$(cp -R "$p" "$d/" 2>&1)"; then
      AIF_WORK_COPY_WHY="could not copy $r: $(printf '%s' "$err" | grep -v 'is a socket (not copied)' | sed -n '1,4p' | paste -sd ';' -)"
      return 1
    fi
  done
  return 0
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
  if ! copy="$(mktemp -d "${TMPDIR:-/tmp}/aif-repair-XXXXXX")" || ! copy="$(cd "$copy" && pwd -P)"; then
    AIF_WORK_REPAIR_WHY="could not make a directory to repair the tests in"
    return 1
  fi
  if ! _aif_work_copy_at "$wt" "$base" "$copy"; then
    rm -rf "${copy:?}"
    AIF_WORK_REPAIR_WHY="could not copy the tree to repair the tests in: $AIF_WORK_COPY_WHY"
    return 1
  fi
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
    # The wall clock is asked before this dispatch too (_aif_work_clock_past,
    # inside it): a repair used to run on past it (docs/DEFECTS.md 13.7).
    AIF_WORK_DISPATCH_VIA=repair AIF_WORK_DISPATCH_ATTEMPT="$n"
    _aif_work_dispatch "$copy" "$ticket" tests "$agent" "$complaint" "$budget_left" "$out" || rc=$?
    AIF_WORK_DISPATCH_VIA="" AIF_WORK_DISPATCH_ATTEMPT=""
    AIF_WORK_REPAIR_SPENT="$(awk -v s="${AIF_WORK_REPAIR_SPENT:-0}" -v c="${AIF_WORK_DISPATCH_EXTRA:-0}" 'BEGIN { printf "%.4f", s + c }')"
    if [ "$rc" -eq 3 ]; then
      rm -f "$out"
      AIF_WORK_REPAIR_WHY="${AIF_WORK_DISPATCH_WHY:-the runner could not run the tests station for the repair — the environment, not the ticket.}"
      break
    fi
    if [ "$rc" -eq 4 ]; then
      rm -f "$out"
      AIF_WORK_REPAIR_WHY="$(_aif_work_clock_why)"
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
  aif_git_own "$wt" add -- "$AIF_TASKS_DIR/$ticket" >/dev/null 2>&1 || true
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$wt/$f" ] || continue
    aif_git_own "$wt" add -- "$f" >/dev/null 2>&1 || true
  done <<EOF
$test_files
EOF
  if ! git -C "$wt" diff --cached --quiet 2>/dev/null; then
    aif_git_own "$wt" -c user.email="aif@local" -c user.name="aif" \
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
# that failed, a gate with no verdict, a merge git would not start, a runner
# that did not answer or whose limit holds past a run · 4 the run's wall clock,
# reached before a dispatch (AIF_WORK_SYNC_WHY says it).
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
  if [ -n "$(aif_git_own "$wt" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    aif_git_own "$wt" add -A "$AIF_TASKS_DIR/$ticket" >/dev/null 2>&1 || true
    aif_git_own "$wt" -c user.email="aif@local" -c user.name="aif" \
      commit -q -m "aif: record $ticket before the sync" >/dev/null 2>&1 || true
  fi
  pre="$(git -C "$wt" rev-parse HEAD)"
  _aif_work_say "sync" "aif/$ticket onto $target_name at ${target:0:7}"

  if ! aif_git_own "$wt" -c merge.conflictStyle=diff3 merge --no-ff --no-commit "$target" >/dev/null 2>&1; then
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
      # The wall clock is asked before this dispatch too (inside it): a sync
      # used to run on past it (docs/DEFECTS.md 13.7).
      AIF_WORK_DISPATCH_VIA=sync AIF_WORK_DISPATCH_ATTEMPT="$n"
      _aif_work_dispatch "$wt" "$ticket" implement "$agent" "$complaint" "$budget_left" "$out" || rc=$?
      AIF_WORK_DISPATCH_VIA="" AIF_WORK_DISPATCH_ATTEMPT=""
      AIF_WORK_SYNC_SPENT="$(awk -v s="$AIF_WORK_SYNC_SPENT" -v c="${AIF_WORK_DISPATCH_EXTRA:-0}" 'BEGIN { printf "%.4f", s + c }')"
      if [ "$rc" -eq 3 ]; then
        rm -f "$out"
        AIF_WORK_SYNC_WHY="${AIF_WORK_DISPATCH_WHY:-the runner could not run the implement station for the sync — the environment, not the ticket}"
        _aif_work_sync_abort "$wt" "$pre"
        return 3
      fi
      if [ "$rc" -eq 4 ]; then
        rm -f "$out"
        AIF_WORK_SYNC_WHY="$(_aif_work_clock_why)"
        _aif_work_sync_abort "$wt" "$pre"
        return 4
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
      aif_git_own "$wt" add -A >/dev/null 2>&1 || true
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

  aif_git_own "$wt" add -A >/dev/null 2>&1 || true
  if ! aif_git_own "$wt" -c user.email="aif@local" -c user.name="aif" commit -q --cleanup=strip \
    -m "aif: sync $ticket onto $target_name at ${target:0:7}" \
    -m "$(_aif_work_sync_body "$left" "$lockfiles" "$n")" >/dev/null 2>&1; then
    AIF_WORK_SYNC_WHY="could not commit the merge of $target_name into aif/$ticket"
    _aif_work_sync_abort "$wt" "$pre"
    return 3
  fi
  # The merged tree, judged by green and scope above, is the one the land
  # meets: `judged` moves to it (lib/cmd_land.sh; docs/DEFECTS.md 13.5).
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags below
  aif_run_update "$work" \
    '.syncs = ((.syncs // 0) + 1)
     | .sync = { onto: $t, name: $name, pre: $pre, post: $post, at: $at,
                 settled: ($settled | split("\n") | map(select(length > 0)
                   | split("\t") | { path: .[0], owner: .[1] })),
                 station: ($left | split("\n") | map(select(length > 0))),
                 attempts: ($n | tonumber),
                 lockfiles: ($locks | split("\n") | map(select(length > 0))) }
     | .judged = $post' \
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
  aif_git_own "$1" merge --abort >/dev/null 2>&1 || true
  aif_git_own "$1" reset -q --hard "$2" >/dev/null 2>&1 || true
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
  aif_git_own "$wt" add -A "$AIF_TASKS_DIR/$ticket" >/dev/null 2>&1 || true
  if ! git -C "$wt" diff --cached --quiet 2>/dev/null; then
    aif_git_own "$wt" -c user.email="aif@local" -c user.name="aif" \
      commit -q -m "aif: record $ticket — the build kept at $ref" >/dev/null 2>&1 || true
  fi
  old="$(git -C "$wt" rev-parse HEAD)"
  if ! aif_git_own "$root" update-ref "$ref" "$old" >/dev/null 2>&1; then
    AIF_WORK_REBUILD_WHY="$why — and the build could not be kept at $ref, so it was not built again"
    return 1
  fi
  old_plan="$(git -C "$wt" show "$old:$AIF_TASKS_DIR/$ticket/plan.md" 2>/dev/null | sed -n '1,150p')" || old_plan=""
  keep="$(mktemp "${TMPDIR:-/tmp}/aif-ticket-XXXXXX")"
  cp "$work/ticket.md" "$keep" 2>/dev/null || true
  aif_git_own "$wt" reset -q --hard "$target" >/dev/null 2>&1 || {
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
  aif_git_own "$wt" add -A "$AIF_TASKS_DIR/$ticket" >/dev/null 2>&1 || true
  aif_git_own "$wt" -c user.email="aif@local" -c user.name="aif" \
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
  # The time spent waiting on the runner — a limit's pause, a backoff — is
  # in the minutes above and outside the wall clock: said beside them, and
  # each wait in its own section below (docs/DEFECTS.md 13.7).
  local waited_s waited_say=""
  waited_s="$(jq -r '[ (.runner_waits // [])[] | (.waited_s // 0) ] | add // 0' "$run" 2>/dev/null)" || waited_s=0
  case "$waited_s" in
    '' | *[!0-9]*) waited_s=0 ;;
  esac
  [ "$waited_s" -eq 0 ] || waited_say=" · waited $(_aif_work_dur "$waited_s") on the runner"

  jq --arg st "$status" --arg why "$why" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '.status = $st | .why = (if $why == "" then null else $why end) | .finished_at = $at' \
    "$run" >"$run.tmp" && mv "$run.tmp" "$run"

  # Everything written here is markdown: the backticks are code spans, not
  # command substitution, and the single quotes are what keeps them that way.
  # shellcheck disable=SC2016
  {
    printf '# %s — %s\n\n' "$ticket" "$status"
    printf -- '- branch `%s` · %s · %s min%s · %s dispatch(es) · stage `%s`\n' \
      "$(jq -r '.branch' "$run")" "$diffstat" "$mins" "$waited_say" \
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
        + (if ((.red_with_tests // []) | length) > 0 then ", " + ((.red_with_tests | length) | tostring) + " pre-existing red with them" else "" end)
        + (if ((.standing // []) | length) > 0 then ", " + ((.standing | length) | tostring) + " standing" else "" end)' \
        "$work/tests.lock.json" 2>/dev/null
    else
      printf -- '- tests: nothing frozen\n'
    fi
    jq -r '"- loops: " + ((.repairs // 0) | tostring) + " repair(s) of the oracle, " + ((.replans // 0) | tostring) + " replan(s)"' "$run" 2>/dev/null

    # What the gates let through — a test or a check red before this ticket,
    # on the tree it was built from, or a test that failed once and passed on
    # a re-run: not this ticket's to answer for, and no longer a stop for it,
    # so it is said where the reviewer reads (docs/DEFECTS.md 13.9). From the
    # lock (verify-red), the ledger's let-through rows (green) and its check
    # rows let through; once each, with every phase that let it through.
    local let_lines lg="/dev/null" lk="/dev/null"
    [ ! -f "$ledger" ] || lg="$ledger"
    [ ! -f "$work/tests.lock.json" ] || lk="$work/tests.lock.json"
    let_lines="$(jq -rn --slurpfile lk "$lk" --slurpfile lg "$lg" '
      ($lk[0] // {}) as $L
      | [ (($L.red_at_base // [])[] | { what: ("`" + . + "`"), kind: "before", phase: "verify-red" }),
          (($L.flaky // [])[] | { what: ("`" + . + "`"), kind: "flaky", phase: "verify-red" }),
          (($lg[0].entries // [])[] | select(.event == "let-through")
            | { what: ("`" + (.test // "?") + "`"), kind: (.kind // "before"), phase: (.phase // "green") }),
          (($lg[0].entries // [])[] | select(.event == "check" and .result == "at_base")
            | { what: ("check `" + (.check // "?") + "`"), kind: "check", phase: (.phase // "?") }) ]
      | group_by([.what, .kind])
      | map({ what: .[0].what, kind: .[0].kind, phases: (map(.phase) | unique) })
      | .[] | "- " + .what + " — "
        + (if .kind == "flaky" then "flaky: failed once, passed on a re-run of the same tree"
           elif .kind == "check" then "fails the same way before this ticket, and nothing new with it"
           else "red before this ticket" end)
        + " (" + (.phases | join(", ")) + ")"' 2>/dev/null)" || let_lines=""
    if [ -n "$let_lines" ]; then
      printf '\n## Let through — red before this ticket, or flaky\n\n'
      printf 'Not this ticket'"'"'s to answer for, and not held against it: red on the tree it was\n'
      printf 'built from, before any of its work — measured there — or failed once and passed on a\n'
      printf 're-run of the same tree. Each is still that way where it lands; look at it there.\n\n'
      printf '%s\n' "$let_lines"
    fi

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

    # Every try the runner cut off — a usage limit, a runner that did not
    # answer — dispatched again, the attempt uncounted, and none of it billed
    # to the station (docs/DEFECTS.md 13.7): what it was, what the stream said,
    # and how long the run waited on it.
    if [ "$(jq -r '(.runner_waits // []) | length' "$run" 2>/dev/null)" != "0" ]; then
      printf '\n## Waited on the runner\n\n'
      printf 'Tries the runner cut off, not the station: dispatched again as the same\n'
      printf 'attempt, uncounted, the wait outside the wall clock — or, the last of them,\n'
      printf 'where the run stopped on the environment.\n\n'
      jq -r '(.runner_waits // [])[]
        | "- `" + .stage + "`" + (if (.via // "stage") != "stage" then " (" + .via + ")" else "" end)
          + " attempt " + ((.attempt // "?") | tostring) + " — " + .class + " (" + .type + ")"
          + (if (.why // "") != "" then ": " + .why else "" end)
          + " — waited " + (if (.waited_s // 0) >= 60 then "\((.waited_s / 60) | floor) min" else "\(.waited_s // 0) s" end)
          + (if (.turns // 0) > 0 then ", after \(.turns) turn(s)" else "" end)' "$run" 2>/dev/null
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

  aif_git_own "$wt" add -A "$AIF_TASKS_DIR/$ticket" >/dev/null 2>&1 || true
  if ! git -C "$wt" diff --cached --quiet 2>/dev/null; then
    aif_git_own "$wt" -c user.email="aif@local" -c user.name="aif" \
      commit -q -m "aif: report $ticket ($status)" >/dev/null 2>&1 || true
  fi

  printf '\n'
  cat "$report"
  printf '\n%s%s%s\n' "$AIF_C_DIM" "${report#"$root"/}" "$AIF_C_RESET"
}

# _aif_work_loop <root> <max> <profile> <budget> <budget_off> <max_minutes>
#                <use_worktree> <parallel> <tui> <idle> <profile_name> — drain
#                Ready, <parallel> runs at a time; <tui> is auto or off; <idle>
#                1 waits for Ready to fill instead of ending. <profile> is the
#                --profile the caller was given, empty or not, and goes to every
#                worker as it came; <profile_name> is the one that resolved to
#                (.aif/profile.local when none was given), which the loop's
#                own second preflight needs — an empty name is no profile.
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
#             ended. Installs and suite probes do not run side by side.
#   preflight once, before the first worker. Its suite probe runs in this
#             checkout, removing the report and waiting for it to appear; N at
#             once would delete each other's. Each worker gets AIF_WORK_LOOP=1
#             and skips only that.
#   exit 3    a worker that could not start — exit 3, or exit 1 in its claim,
#             worktree or intake, which its handler labels blocked:
#             environment — is the machine's trouble or one card's hiccup (an
#             install that met the network, one 429), and one of them used to
#             stop the loop (docs/DEFECTS.md 13.8). So the loop asks the
#             machine again — its own preflight, in a subshell, without the
#             suite probe — and goes on when that passes, stopping when it
#             fails or at the third such card in a row. A machine that cannot
#             run anything costs at most three cards in Needs Human, and only
#             for trouble the preflight cannot see. Those cards do not count
#             toward two in a row: the machine is not a verdict on the cards.
#             A loop whose every card hit the environment, but never three in
#             a row, ends on an empty Ready with rc 1 and env 0 in its summary,
#             rechecks saying how often the machine was asked again. A Ready
#             that could not be read is asked about the same way. A worker
#             that refused to take over a dead run whose processes still run
#             is neither: the card is held (docs/DEFECTS.md 14.1, 13.8).
#   one loop  per checkout, through the loop lock (aif_loop_lock_dir), taken
#             before the preflight; a second is refused with exit 3 and
#             touches nothing. In it, `aif work --loop --drain` and `--stop`
#             leave the files the loop reads at the top of every second.
#   output    each worker writes its own log under .aif/tmp/loop-<when>/ — or
#             under AIF_WORK_LOOP_LOGDIR, so a parent can name the directory it
#             will read — one a take, a card taken again writing <ID>.2.log
#             (docs/DEFECTS.md 15.7). On a terminal the loop draws its dashboard (lib/tui.sh)
#             from what each worker writes into its run lock as it moves;
#             anywhere else it says one line per start and per end. A summary
#             either way, and summary.json beside the logs for a parent.
#   Ctrl-C    each worker starts in a process group of its own, so the
#             terminal's Ctrl-C reaches the loop alone. The first takes no new
#             card and lets the runs in flight finish; the second stops them,
#             each settling its card as stopped by Ctrl-C. `set -m` is on only
#             around the spawn: left on, bash hands the terminal to every
#             foreground command it runs — a jq, a curl, the tick's sleep — and
#             a Ctrl-C then reaches that command and not the loop. The tick's
#             second is spent in the `wait` builtin, where a Ctrl-C always
#             runs the handler (_aif_work_loop_tick, docs/DEFECTS.md 11.1).
#
# Takes no new card when Ready has none it has not taken — unless --idle, when
# it looks again every AIF_WORK_LOOP_POLL seconds (30) and goes on — at
# --max-tickets, when workers could not start and the machine fails its
# preflight again or three did in a row, after two that did not build with
# none built between them, on Ctrl-C, or on `aif work --loop --drain`; then
# waits for the runs in flight and says how each ended. `aif work --loop
# --stop` stops the runs in flight as well, as a TERM does. A run stopped on
# its own — `aif work <ID> --stop`, or [s] on the dashboard — is not a
# verdict on the cards: it does not count toward two in a row, and its slot
# takes the next card.
#
# Idle, the taken list forgets a card once it has left Ready: one that comes
# back — a land's sync:, a shift's retry, a person's move — is the loop's
# again, while one still sitting in Ready after its run ended stays skipped
# (named as held), until the machine has been asked again and passed. What
# it holds, and why each, is in its lock's owner.json as it changes, for a
# shift in another terminal (docs/DEFECTS.md 15.3).
#
# Exit: 0 every ticket taken was built · 1 some were not · 3 stopped on the
# environment, or another loop holds this checkout · 130 / 143 stopped by
# Ctrl-C (or q) or by a TERM or `aif work --loop --stop` · 129 the terminal
# closed over it (HUP), the runs in flight stopped too. A drain ends as the
# runs it waited for did: 0 when every card taken was built, else 1.
# The dashboard's state: read by lib/tui.sh, which a linter reading this file cannot see.
# shellcheck disable=SC2034
_aif_work_loop() {
  local root="$1" max="$2" profile="$3" budget="$4" budget_off="$5"
  local max_minutes="$6" use_worktree="$7" parallel="${8:-1}" tui="${9:-auto}"
  local idle="${10:-0}" profile_name="${11:-}"
  local main logdir why="" env=0 taken_n=0 in_a_row=0 next_poll=0 kill_by=0
  local now n list pick id pid rc entry left what kind mins results="" slot st i
  local poll idling=0 unread=0 read_ok env_in_a_row=0 rechecks=0 envhit rc2
  local who drained=0 abs log held_by why_now err rl unread_n=0 taken_on land_pid

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
  # A parent that starts the loop names the directory, so it knows where the
  # logs and summary.json will be before the loop prints anything — a
  # timestamped name is found only by listing after the fact (docs/DEFECTS.md
  # 14.3).
  logdir="${AIF_WORK_LOOP_LOGDIR:-$main/.aif/tmp/loop-$(date '+%Y%m%d-%H%M%S')}"
  mkdir -p "$logdir"
  # A directory a parent names may be one it named before: the summary in it
  # is the last loop's end, and would be read as this one's by whoever polls
  # for the file — and taken by the EXIT handler as already written.
  rm -f "$logdir/summary.json"
  # Into the loop lock at once, absolute: a shift in another terminal, or
  # `aif work --loop --stop` from anywhere, finds the summary through it.
  # Not having written it costs them the summary, not the loop its run.
  if [ -n "${AIF_WORK_LOOP_LOCK:-}" ]; then
    abs="$(cd "$logdir" 2>/dev/null && pwd -P)" || abs="$logdir"
    # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
    if ! { jq --arg d "$abs" '.logdir = $d' "$AIF_WORK_LOOP_LOCK/owner.json" >"$AIF_WORK_LOOP_LOCK/owner.json.tmp" &&
      mv "$AIF_WORK_LOOP_LOCK/owner.json.tmp" "$AIF_WORK_LOOP_LOCK/owner.json"; } 2>/dev/null; then
      rm -f "$AIF_WORK_LOOP_LOCK/owner.json.tmp" 2>/dev/null || true
      aif_warn "could not write the log directory into the loop lock — aif work --loop --stop and aif start will not find this loop's summary"
    fi
  fi
  # How often an empty Ready, or one with nothing left to take, is read again.
  # Every look at a Trello board is a request, and the dashboard's look is the
  # loop's own (_aif_work_loop_refresh). AIF_WORK_LOOP_POLL is the harness's
  # seam: an idle loop that looked every 30 seconds would take a minute to
  # test.
  poll="${AIF_WORK_LOOP_POLL:-30}"
  case "$poll" in
    '' | *[!0-9]*) poll=30 ;;
  esac

  # What the loop, its handler and its dashboard share, in globals: a trap
  # fires with the signal's name only, and lib/tui.sh draws from these.
  AIF_WORK_LOOP_ROOT="$root"
  AIF_WORK_LOOP_MAIN="$main"
  AIF_WORK_LOOP_LOGDIR="$logdir"
  AIF_WORK_LOOP_TAKEN=" "   # every card taken, space-delimited
  AIF_WORK_LOOP_STOP=""     # why no new card is taken — the first reason wins
  AIF_WORK_LOOP_CTRL_C=0    # how many Ctrl-Cs (or q) have arrived
  AIF_WORK_LOOP_KILLED=""   # INT or TERM, once every run in flight was told to stop
  AIF_WORK_LOOP_HUP=0       # 1 once the terminal closed over the loop (HUP)
  AIF_WORK_LOOP_RUNNING=""  # "<pid>:<ticket>:<started>:<slot>" per run in flight
  AIF_WORK_LOOP_IDLE=0      # 1 while an idle loop has nothing to take and nothing running
  AIF_WORK_LOOP_POLL_S="$poll"
  AIF_WORK_LOOP_HELD=""     # taken cards still in Ready, skipped — named, not hidden
  AIF_WORK_LOOP_WHYS=""     # "<id>|<how its last run here ended>", a line a card: why one is held
  AIF_WORK_LOOP_HELD_PUB="" # the held cards as the loop lock's owner.json last said them
  AIF_WORK_LOOP_TAKES=" "   # every take, an id once per take: which log the next one writes
  AIF_WORK_LOOP_IDLE_WHY="" # what an idle loop says of Ready: empty, or what it holds
  AIF_WORK_LOOP_READY=""    # the last Ready read, the loop's or the dashboard's
  AIF_WORK_LOOP_READ_AT=0   # when that was
  AIF_WORK_LOOP_PAUSED=""   # "paused until HH:MM — <limit>, met by <ID>" while the runner's limit holds
  AIF_WORK_LOOP_PAUSE_SEEN="" # the reset that line was said for
  AIF_WORK_LOOP_PAUSE_HELD=0  # 1 while the limit holds past what the loop waits
  AIF_WORK_LOOP_PAUSE_OVER=0  # 1 once, when a pause has just ended
  AIF_WORK_LOOP_HOLD_WHY=""   # what the loop says when it stops on a held limit
  AIF_WORK_LOOP_PAUSE_FILE="$(aif_pause_file "$root")"
  AIF_TUI_PARALLEL="$parallel" AIF_TUI_STARTED="$(date +%s)" AIF_TUI_NOW="$AIF_TUI_STARTED"
  # The clock and the run locks' directory, read once and then computed with
  # builtins: what the loop does every second forks as little as it can. A
  # Ctrl-C that lands in a `$(…)` the loop waits on kills the child, and under
  # set -e the assignment it fed then ends the loop itself — its runs left
  # building, the second Ctrl-C never forwarded (probed; docs/DEFECTS.md
  # 11.1, docs/FINDINGS.md #33). SECONDS is the shell's own count of them.
  AIF_WORK_LOOP_EPOCH=$((AIF_TUI_STARTED - SECONDS))
  AIF_WORK_LOOP_RUNS="$(dirname "$(aif_run_lock_dir "$root" x)")"
  AIF_TUI_BUILT=0 AIF_TUI_BLOCKED=0 AIF_TUI_STOPPED=0 AIF_TUI_READY="" AIF_TUI_LOAD="" AIF_TUI_DISK=""
  AIF_TUI_EVENTS="" AIF_TUI_SEL=1 AIF_TUI_BOTTOM=events AIF_TUI_LOG="" AIF_TUI_ASK=""
  for i in $(seq 1 "$parallel"); do
    AIF_LS_PID[i]="" AIF_LS_ID[i]="" AIF_LS_RESULT[i]="" AIF_LS_KIND[i]="" AIF_LS_LIVE[i]=""
    AIF_LS_START[i]="" AIF_LS_END[i]="" AIF_LS_PCT[i]=0 AIF_LS_PSTAGE[i]=0 AIF_LS_LOG[i]=""
  done
  _aif_work_loop_tui_start "$tui"
  aif_trap_arm "_aif_work_loop_signal"

  [ "$AIF_WORK_LOOP_TUI" = 1 ] ||
    printf '\n%sloop%s %s at a time · logs in %s\n' "$AIF_C_BOLD" "$AIF_C_RESET" "$parallel" "${logdir#"$main"/}" >&2

  while :; do
    # What `aif work --loop --drain|--stop` left in the loop lock, read with
    # builtins alone — a test and a read, no fork — so looking every second
    # opens no new window for the signal a fork's wait can lose
    # (docs/DEFECTS.md 11.1). A stop is a person's, not a signal's: each run
    # in flight is told so through its own run lock before the TERM, and its
    # card says who stopped it, as `aif work <ID> --stop` would have — a stop
    # nobody meant (a TERM, a hang-up) is the one a shift may retry.
    if [ -n "${AIF_WORK_LOOP_LOCK:-}" ]; then
      if [ -f "$AIF_WORK_LOOP_LOCK/stop" ] && [ -z "$AIF_WORK_LOOP_KILLED" ]; then
        who=""
        IFS= read -r who <"$AIF_WORK_LOOP_LOCK/stop" || true
        AIF_WORK_LOOP_STOP="stopped by ${who:-someone} (aif work --loop --stop) — the runs in flight were stopped too"
        _aif_work_loop_event red "stopped by ${who:-someone} (aif work --loop --stop)"
        _aif_work_loop_stop_runs "${who:-someone}"
        _aif_work_loop_forward TERM
      elif [ "$drained" -eq 0 ] && [ -f "$AIF_WORK_LOOP_LOCK/drain" ]; then
        drained=1
        who=""
        IFS= read -r who <"$AIF_WORK_LOOP_LOCK/drain" || true
        [ -n "$AIF_WORK_LOOP_STOP" ] ||
          AIF_WORK_LOOP_STOP="drained by ${who:-someone} (aif work --loop --drain) — no new card taken"
        _aif_work_loop_event yellow "drained by ${who:-someone} (aif work --loop --drain) — no new card; the runs in flight finish"
      fi
    fi

    # The runner's usage limit, met by a worker and written where every
    # process of this checkout reads it (_aif_work_pause_write): while it
    # pauses, no new card — a new card starts at the plan station, opus, and
    # whatever the limit's scope, the loop would only start workers to wait
    # beside the ones already waiting; past what a run waits, or with no
    # reset, the loop stops on the environment, naming when to come back.
    # Read before the reaper, so a worker that stopped on a held limit is not
    # taken for a machine to check again (docs/DEFECTS.md 13.7, 13.8).
    _aif_work_loop_pause
    if [ "$AIF_WORK_LOOP_PAUSE_HELD" = 1 ] && [ -z "$AIF_WORK_LOOP_STOP" ]; then
      AIF_WORK_LOOP_STOP="$AIF_WORK_LOOP_HOLD_WHY"
      env=1
      _aif_work_loop_event red "$AIF_WORK_LOOP_HOLD_WHY"
    fi
    if [ "$AIF_WORK_LOOP_PAUSE_OVER" = 1 ]; then
      AIF_WORK_LOOP_PAUSE_OVER=0
      next_poll=0
    fi

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
      now=$((AIF_WORK_LOOP_EPOCH + SECONDS))
      mins=$(((now - st) / 60))
      AIF_LS_PID[slot]=""
      AIF_LS_END[slot]="$now"
      # This take's own log (_aif_work_loop_take_log), and the last error its
      # worker printed there: what the loop says of the card should it hold it.
      log="${AIF_LS_LOG[slot]:-$id.log}"
      err="$(sed -n 's/^error: //p' "$logdir/$log" 2>/dev/null | tail -1)" || err=""
      kind=""
      envhit=""
      case "$rc" in
        0)
          AIF_TUI_BUILT=$((AIF_TUI_BUILT + 1))
          in_a_row=0
          env_in_a_row=0
          what="built → Review"
          why_now="its run here built it, and it was back in Ready before this loop saw it leave"
          AIF_LS_RESULT[slot]=built
          _aif_work_loop_event green "$id built → Review · $mins min"
          ;;
        3)
          # A takeover the worker refused because what a dead run of the card
          # started still runs (_aif_work_lock_orphans, its fixed line read
          # back the way the blocked: kind is below): the card untouched, and
          # nothing about the machine — a person's shell open in the worktree
          # refuses it the same way. Counted toward the environment, three
          # such cards stopped an idle loop that had a fourth to build, and
          # each was a preflight asked again for nothing (docs/DEFECTS.md
          # 14.1, 13.8). Held instead, its why published (15.3); the exit codes
          # stay the documented contract.
          held_by="$(sed -n 's/.* last worker is gone, and what it started still runs: \(.*\) — not taken over\..*/\1/p' "$logdir/$log" 2>/dev/null | tail -1)" || held_by=""
          # And a card another machine's worker has — its claim live, read
          # before the take or found earlier than this worker's own after it
          # (_aif_work_claim_check, _aif_work_claim_race): that machine's, and
          # nothing about this one (docs/DEFECTS.md 14.4).
          taken_on="$(sed -n "s/.* is taken on \(.*\) — skipped: another machine's worker has it\..*/\1/p" "$logdir/$log" 2>/dev/null | tail -1)" || taken_on=""
          # And a card an `aif land` of it holds in this checkout: the land's
          # until it ends, and nothing about the machine — its fixed line read
          # back the same way (docs/DEFECTS.md 15.1, 13.8).
          land_pid="$(sed -n 's/.*aif land [^ ]* runs in this checkout right now (pid \([0-9]*\)).*/\1/p' "$logdir/$log" 2>/dev/null | tail -1)" || land_pid=""
          if [ -n "$held_by" ]; then
            what="not taken over (exit 3) — what its last run started still runs"
            why_now="its last worker is gone, and what it started still runs: $held_by — aif work --status $id says what"
            AIF_LS_RESULT[slot]=held
            _aif_work_loop_event yellow "$id not taken over — what its last worker started still runs ($held_by); the card is held, the loop goes on · aif work --status $id"
          elif [ -n "$taken_on" ]; then
            what="not taken (exit 3) — another machine's worker has it"
            why_now="taken on $taken_on — another machine's worker has it"
            AIF_LS_RESULT[slot]=held
            _aif_work_loop_event yellow "$id is taken on another machine — $taken_on; the card is held, the loop goes on"
          elif [ -n "$land_pid" ]; then
            what="not taken (exit 3) — aif land $id runs on it here"
            why_now="aif land $id runs in this checkout (pid $land_pid) — its worktree is the land's until it ends"
            AIF_LS_RESULT[slot]=held
            _aif_work_loop_event yellow "$id is being landed here (aif land, pid $land_pid); the card is held, the loop goes on"
          else
            what="could not start (exit 3)"
            why_now="its worker could not start (exit 3)${err:+: $err}"
            AIF_LS_RESULT[slot]="env"
            envhit="$id could not start (exit 3) — the environment, not the card"
          fi
          ;;
        # 129 as well: a worker whose own group was hung up on — not by this
        # loop, which forwards a TERM — was stopped, not judged, like the
        # other two.
        129 | 130 | 143)
          what="stopped (exit $rc)"
          why_now="its worker was stopped (exit $rc) before it took the card"
          AIF_TUI_STOPPED=$((AIF_TUI_STOPPED + 1))
          AIF_LS_RESULT[slot]=stopped
          if [ -z "$AIF_WORK_LOOP_KILLED" ] && [ "$AIF_WORK_LOOP_CTRL_C" -eq 0 ]; then
            _aif_work_loop_event dim "$id was stopped (exit $rc) — not counted against the cards; the loop goes on"
          else
            _aif_work_loop_event dim "$id stopped (exit $rc)"
          fi
          ;;
        *)
          kind="$(sed -n 's/.*→ needs_human — blocked: \([a-z]*\).*/\1/p' "$logdir/$log" 2>/dev/null | tail -1)" || kind=""
          # No blocked: line in its log is a worker that never moved the
          # card — it exited before its claim, in its own preflight — and the
          # card is still in Ready, not in Needs Human: said so, in the
          # results row and as why the loop holds it (docs/DEFECTS.md 15.3).
          if [ -n "$kind" ]; then
            what="not built → Needs Human, blocked: $kind"
            why_now="its run here ended blocked: $kind, and it was back in Ready before this loop saw it leave"
          else
            what="not built — its worker exited $rc before it took the card"
            why_now="its worker exited $rc before it took the card${err:+: $err}"
          fi
          AIF_TUI_BLOCKED=$((AIF_TUI_BLOCKED + 1))
          AIF_LS_RESULT[slot]=blocked
          _aif_work_loop_event red "$id $what · $mins min"
          if [ "$kind" = environment ]; then
            # Its handler's label for an exit in the claim, the worktree or
            # the intake — before any station ran: the machine, as an exit 3
            # is, and asked again the same way below. Not two in a row: that
            # stop reads the cards, and this was not about the card
            # (docs/DEFECTS.md 13.8).
            envhit="$id could not start — the environment, not the card"
          else
            env_in_a_row=0
            in_a_row=$((in_a_row + 1))
            if [ "$in_a_row" -ge 2 ] && [ -z "$AIF_WORK_LOOP_STOP" ]; then
              AIF_WORK_LOOP_STOP="two runs in a row did not build ($id the last) — read the cards in Needs Human before spending on a third"
            fi
          fi
          ;;
      esac
      # A worker that could not start: the machine asked again before it
      # stops the loop (the design comment above, "exit 3"). The preflight in
      # a subshell — it exits on every refusal, and a subshell's exit runs no
      # trap of this loop (bash 3.2, checked) — with AIF_WORK_LOOP=1, so the
      # suite is not probed in the developer's checkout again, and with the
      # profile it resolved to, not the --profile that may have been empty.
      # Not once a stop is set: nothing new will be taken either way.
      if [ -n "$envhit" ]; then
        env_in_a_row=$((env_in_a_row + 1))
        if [ "$env_in_a_row" -ge 3 ]; then
          [ -n "$AIF_WORK_LOOP_STOP" ] ||
            AIF_WORK_LOOP_STOP="$envhit; the loop takes no new card (three in a row)"
          env=1
          _aif_work_loop_event red "$envhit; the third in a row, so the loop takes no new card — its log says what"
        elif [ -z "$AIF_WORK_LOOP_STOP" ]; then
          _aif_work_loop_event red "$id could not start (exit $rc) — checking the machine again"
          rc2=0
          (AIF_WORK_LOOP=1 _aif_work_preflight "$root" "$profile_name") >>"$logdir/loop.log" 2>&1 || rc2=$?
          if [ "$rc2" -eq 0 ]; then
            rechecks=$((rechecks + 1))
            _aif_work_loop_event yellow "$id could not start, but the machine checks out (preflight passed) — the loop goes on ($env_in_a_row of 3)"
            # Idle, the card is the loop's again should it come back to
            # Ready: what stopped it was not the card, and the machine now
            # passes. Three in a row bound a card that fails each time.
            [ "$idle" -eq 0 ] || _aif_work_loop_forget "$id"
          elif [ "$rc2" -le 128 ]; then
            [ -n "$AIF_WORK_LOOP_STOP" ] ||
              AIF_WORK_LOOP_STOP="$id could not start, and the preflight fails again — the environment, not the card; the loop takes no new card"
            env=1
            _aif_work_loop_event red "$id could not start, and the preflight fails again (exit $rc2) — the environment, not the card; loop.log has what it said"
          fi
          # rc2 above 128: the preflight was interrupted — a Ctrl-C reaches
          # this subshell as it reaches the loop — and the loop's handler has
          # what the signal meant.
        else
          _aif_work_loop_event red "$envhit — its log says what"
        fi
      fi
      AIF_LS_KIND[slot]="$kind"
      _aif_work_loop_why_set "$id" "$why_now"
      results="$results$id|$what|$mins|$log
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
      [ "$kill_by" -ne 0 ] || kill_by=$((AIF_WORK_LOOP_EPOCH + SECONDS + 60))
      if [ $((AIF_WORK_LOOP_EPOCH + SECONDS)) -gt "$kill_by" ]; then
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
    elif [ "$n" -lt "$parallel" ] && [ -z "$AIF_WORK_LOOP_PAUSED" ] && ! _aif_work_loop_starting "$root"; then
      now=$((AIF_WORK_LOOP_EPOCH + SECONDS))
      if [ "$now" -ge "$next_poll" ]; then
        pick=""
        read_ok=0
        rl=0
        list="$(aif_board_ready_list "$root" 2>/dev/null)" || rl=$?
        if [ "$rl" -eq 0 ]; then
          read_ok=1
          unread=0
          unread_n=0
          # The dashboard shows this read, and makes none of its own while
          # this one is fresh (_aif_work_loop_refresh).
          AIF_WORK_LOOP_READY="$list"
          AIF_WORK_LOOP_READ_AT="$now"
          _aif_work_loop_prune "$list" "$idle"
          _aif_work_loop_held_publish
          for id in $list; do
            case "$AIF_WORK_LOOP_TAKEN" in
              *" $id "*) continue ;;
            esac
            # A worker in another terminal holds it: not this loop's — for
            # good, or, idle, for this poll only: that worker ends, and the
            # card, should it still be in Ready then, is the loop's.
            if _aif_work_lock_live "$AIF_WORK_LOOP_RUNS/$id"; then
              if [ "$idle" -eq 0 ]; then
                AIF_WORK_LOOP_TAKEN="$AIF_WORK_LOOP_TAKEN$id "
                _aif_work_loop_why_set "$id" "a worker in another terminal was building it when this loop looked"
              fi
              continue
            fi
            pick="$id"
            break
          done
        elif [ -n "$AIF_WORK_LOOP_STOP" ] || [ "$rl" -gt 128 ]; then
          # A signal that came during the read ended the read, not the board:
          # a Ctrl-C reaches the `$(…)` with the loop, and the loop's own
          # handler has what it meant — the top of the next iteration acts on
          # it. Read as the board, it ended the loop with env 1 in its summary
          # beside a 130, which a reader of `env` takes for the machine
          # (docs/DEFECTS.md 15.9).
          :
        elif [ "$n" -eq 0 ] && [ "$idle" -eq 0 ]; then
          # Nothing running, nothing read, and not idle: the end — as the
          # machine only once the machine has been asked again, as a worker
          # that could not start is (below, docs/DEFECTS.md 13.8). The rc 3 it
          # ends in is read as the environment, by `aif start` above all,
          # and one read the adapter's own retries could not save was that
          # with no second look (docs/DEFECTS.md 14.3). A preflight that
          # passes — `aif board check` among it — reads Ready again at the
          # next tick, three reads in a row at most.
          unread_n=$((unread_n + 1))
          rc2=0
          (AIF_WORK_LOOP=1 _aif_work_preflight "$root" "$profile_name") >>"$logdir/loop.log" 2>&1 || rc2=$?
          if [ "$rc2" -eq 0 ] && [ "$unread_n" -lt 3 ]; then
            rechecks=$((rechecks + 1))
            _aif_work_loop_event yellow "the board's Ready column could not be read, but the machine checks out (preflight passed) — reading it again ($unread_n of 3)"
            next_poll=0
            _aif_work_loop_tick
            continue
          elif [ "$rc2" -le 128 ]; then
            why="the board's Ready column could not be read"
            if [ "$rc2" -eq 0 ]; then
              why="$why three times in a row, though the preflight passes — aif board check says why"
            else
              why="$why, and the preflight fails again (exit $rc2) — loop.log has what it said"
            fi
            env=1
            break
          fi
          # rc2 above 128: the preflight was interrupted, and the loop's
          # handler has what the signal meant.
        elif [ "$n" -eq 0 ] && [ "$unread" -eq 0 ]; then
          # Idle, a board that does not answer is a board to ask again, not
          # the end of a loop meant to outlast the night — said once a
          # stretch, the loop's preflight having seen it answer.
          unread=1
          _aif_work_loop_event red "the board's Ready column could not be read — looking again in ${poll}s"
        fi
        # The read takes its time — a second or more on Trello, with its
        # retries — and a drain, a stop or a signal that came during it was
        # not there when the top of the iteration looked: the drain answered
        # "takes no new card" and the card was taken; a TERM stopped every run
        # and then started one more, which no signal reached and which built
        # on after its loop was gone. So the same look again, with builtins
        # only, before a card is taken; `continue`, so that the top records
        # who asked and ends the loop as it would have.
        if [ -n "$pick" ] && { [ -n "$AIF_WORK_LOOP_STOP" ] ||
          [ -f "${AIF_WORK_LOOP_LOCK:-/nonexistent}/drain" ] ||
          [ -f "${AIF_WORK_LOOP_LOCK:-/nonexistent}/stop" ]; }; then
          continue
        fi
        # And the runner's limit, which a worker may have met during the
        # read (docs/DEFECTS.md 13.7).
        [ -z "$pick" ] || _aif_work_loop_pause
        if [ -n "$pick" ] && { [ -n "$AIF_WORK_LOOP_PAUSED" ] || [ "$AIF_WORK_LOOP_PAUSE_HELD" = 1 ]; }; then
          continue
        fi
        if [ -n "$pick" ]; then
          AIF_WORK_LOOP_TAKEN="$AIF_WORK_LOOP_TAKEN$pick "
          taken_n=$((taken_n + 1))
          idling=0
          AIF_WORK_LOOP_IDLE=0
          slot=1
          while [ -n "${AIF_LS_PID[slot]}" ]; do
            slot=$((slot + 1))
          done
          _aif_work_loop_take_log "$pick"
          log="$AIF_WORK_LOOP_TAKE_LOG"
          if [ "$AIF_WORK_LOOP_TUI" = 1 ]; then
            _aif_work_loop_event orange "$pick taken · worker $slot · log $log"
          else
            printf '\n%sloop%s %s — %s · %s of %s running · %s\n' "$AIF_C_BOLD" "$AIF_C_RESET" \
              "$taken_n" "$pick" "$((n + 1))" "$parallel" "${logdir#"$main"/}/$log" >&2
          fi
          # A process group of its own, so the terminal's Ctrl-C passes it by
          # — and job control off again at once, or the next foreground
          # command takes the terminal and the next Ctrl-C with it.
          set -m
          AIF_WORK_LOOP=1 "$AIF_ROOT/bin/aif" work "$pick" ${1+"$@"} </dev/null >"$logdir/$log" 2>&1 &
          pid=$!
          set +m
          AIF_WORK_LOOP_RUNNING="${AIF_WORK_LOOP_RUNNING:+$AIF_WORK_LOOP_RUNNING }$pid:$pick:$((AIF_WORK_LOOP_EPOCH + SECONDS)):$slot"
          # A TERM, a hang-up or a second Ctrl-C between the look above and
          # this line was forwarded to every run but this one, which was not
          # in the list yet: it gets the same signal now.
          [ -z "$AIF_WORK_LOOP_KILLED" ] || kill -"$AIF_WORK_LOOP_KILLED" -- "-$pid" 2>/dev/null || kill -"$AIF_WORK_LOOP_KILLED" "$pid" 2>/dev/null || true
          AIF_LS_PID[slot]="$pid" AIF_LS_ID[slot]="$pick" AIF_LS_RESULT[slot]=running AIF_LS_KIND[slot]="" AIF_LS_LOG[slot]="$log"
          AIF_LS_LIVE[slot]="" AIF_LS_START[slot]=$((AIF_WORK_LOOP_EPOCH + SECONDS)) AIF_LS_END[slot]="" AIF_LS_PCT[slot]=0 AIF_LS_PSTAGE[slot]=0
          continue
        fi
        if [ "$read_ok" -eq 1 ] && [ "$n" -eq 0 ]; then
          # What Ready holds when there is nothing in it to take: nothing at
          # all, or only cards this loop will not take again, said as such —
          # "Ready is empty" over a Ready that held them left a person, and
          # a shift, waiting on cards nobody would take (docs/DEFECTS.md
          # 15.3) — or cards workers elsewhere hold.
          _aif_work_loop_idle_why "$list"
          if [ "$idle" -eq 0 ]; then
            why="$AIF_WORK_LOOP_IDLE_WHY"
            break
          fi
          # Idle: not the end — one line on the way in, then a look every
          # poll, until a card comes, a drain, a stop, Ctrl-C or q.
          if [ "$idling" -eq 0 ]; then
            idling=1
            AIF_WORK_LOOP_IDLE=1
            _aif_work_loop_event dim "$AIF_WORK_LOOP_IDLE_WHY — idle, looking again every ${poll}s · Ctrl-C, q or aif work --loop --drain ends the loop${AIF_WORK_LOOP_HELD:+ · held: $AIF_WORK_LOOP_HELD}"
          fi
        fi
        # Nothing to take: look again in a while, not every second — on a
        # Trello board every look is a request.
        next_poll=$((now + poll))
      fi
    fi
    _aif_work_loop_tick
  done
  _aif_work_loop_tui_stop

  [ -z "$AIF_WORK_LOOP_STOP" ] || why="$AIF_WORK_LOOP_STOP"
  printf '\n%sloop%s %s taken, %s built — %s\n' "$AIF_C_BOLD" "$AIF_C_RESET" "$taken_n" "$AIF_TUI_BUILT" "$why" >&2
  # Each run with the log of its own take: a card taken twice has two
  # (docs/DEFECTS.md 15.7).
  while IFS='|' read -r id what mins log; do
    [ -n "$id" ] || continue
    case "$what" in
      built*) printf '  %s · %s min · %s · aif land %s · %s\n' "$id" "$mins" "$what" "$id" "$log" >&2 ;;
      *) printf '  %s · %s min · %s · %s\n' "$id" "$mins" "$what" "$log" >&2 ;;
    esac
  done <<EOF
$results
EOF
  [ "$taken_n" -eq 0 ] || printf '  %slogs: %s/%s\n' "$AIF_C_DIM" "${logdir#"$main"/}" "$AIF_C_RESET" >&2
  _aif_work_loop_summary "$logdir/summary.json" "$taken_n" "$env" "$why" "$results" \
    "$idle" "$rechecks" "$AIF_WORK_LOOP_HELD"
  # The checkout is free for the next loop once the summary is there — `aif
  # work --loop --stop` reads it the moment the lock is gone.
  _aif_work_loop_unlock
  # Disarmed only now: the summary is the last thing the loop owes whoever
  # started it, and while the handler is armed its EXIT branch writes the
  # summary should a print above end the loop first (docs/DEFECTS.md 14.3).
  aif_trap_disarm

  # The hang-up first: it stops the runs with a TERM of its own, and the code
  # has to say what happened to the loop, not what it did about it.
  [ "${AIF_WORK_LOOP_HUP:-0}" -eq 0 ] || exit 129
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
    lock="$AIF_WORK_LOOP_RUNS/$id"
    [ "$(_aif_work_lock_pid "$lock")" = "$pid" ] || return 0
    case "$(cat "$lock/phase" 2>/dev/null)" in
      intake | run | report) ;;
      *) return 0 ;;
    esac
  done
  return 1
}

# _aif_work_loop_summary <file> <taken> <env> <why> <result-lines> <idle>
#                        <rechecks> <held> — how the loop ended, as JSON beside
#                        the logs, for whoever started it and cannot read its
#                        terminal. <held> is space-separated ids.
#
# The exit code says how the loop ENDED, not what the board holds: rc 0 comes
# with a non-empty Ready when a live lock or the taken list skipped a card, or
# at --max-tickets; rc 1 from a preflight die with nothing taken; rc 3 came
# from one 429 (docs/AUTOPILOT-RESEARCH.md §6.11, verification 1;
# docs/DEFECTS.md 14.3), and now only once the machine was asked again — the
# adapter retries the board's calls, and a worker that could not start or a
# Ready that could not be read has the loop's preflight run again first. A
# parent that read the code alone would start a loop again over a Ready it had
# just drained, or hold one that had taken nothing — so the counts, the reason
# — what Ready held when it was not empty — and each run's end are written
# here, and a parent reads the file, never the rc alone (`aif start` does,
# lib/cmd_start.sh _aif_start_run_build). The results array is built by jq
# from the `id|what|minutes|log` lines the loop keeps: the environment carries no arrays,
# bash 3.2 has none worth passing, and jq owns the escaping. Written whole
# — to a temp name, then moved — so a parent polling for it never reads half.
# Not writing it is a warning, not a stop: every run is settled on its card
# already, and the lines on the terminal say the same. Written at the loop's
# end, and by its EXIT branch when something ends the loop before that, so
# the file is there on every path once the logdir is.
#
# Idle and its re-checks are said too: `idle` whether it waited for Ready,
# `rechecks` how often a worker that could not start, or a Ready that could
# not be read, was followed by a preflight that passed — a loop whose every
# card hit the environment ends rc 1 with env 0, and this is what tells it
# from cards that failed on their own — and `held`, the cards it left in
# Ready on purpose. Each results row names its take's log, a file beside
# this one: a card taken twice is two rows, and was one log written over
# (docs/DEFECTS.md 15.7).
_aif_work_loop_summary() {
  local file="$1" taken="$2" env="$3" why="$4" lines="$5" idle="${6:-0}" rechecks="${7:-0}" held="${8:-}" results
  results="$(printf '%s' "$lines" | jq -R -s '
    split("\n") | map(select(length > 0) | split("|")
      | { ticket: .[0], what: .[1], minutes: (.[2] | tonumber? // 0),
          log: (if (.[3] // "") == "" then (.[0] + ".log") else .[3] end) })' 2>/dev/null)" || results="[]"
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  if {
    jq -n --argjson taken "$taken" --argjson built "$AIF_TUI_BUILT" \
      --argjson blocked "$AIF_TUI_BLOCKED" --argjson stopped "$AIF_TUI_STOPPED" \
      --argjson env "$env" --argjson ctrl_c "$AIF_WORK_LOOP_CTRL_C" \
      --arg killed "$AIF_WORK_LOOP_KILLED" --argjson hup "${AIF_WORK_LOOP_HUP:-0}" \
      --arg why "$why" --argjson results "${results:-[]}" \
      --argjson idle "$idle" --argjson rechecks "$rechecks" --arg held "$held" \
      '{ taken: $taken, built: $built, blocked: $blocked, stopped: $stopped, env: $env,
         ctrl_c: $ctrl_c, killed: (if $killed == "" then null else $killed end),
         hup: $hup, why: $why, results: $results,
         idle: $idle, rechecks: $rechecks, held: ($held | split(" ") | map(select(length > 0))) }' >"$file.tmp" &&
      mv "$file.tmp" "$file"
  } 2>/dev/null; then
    return 0
  fi
  rm -f "$file.tmp" 2>/dev/null
  aif_warn "could not write $file — the lines above are the summary"
}

# _aif_work_loop_event <tone> <text> — one thing that happened: into the loop's
# own log, and onto the dashboard, newest first — or, with no dashboard, said.
_aif_work_loop_event() {
  local at ev
  # Each `$(…)` guarded: a Ctrl-C that kills its child would otherwise end
  # the loop through set -e — the first Ctrl-C's own event is said from the
  # handler, where a second may land (docs/DEFECTS.md 11.1).
  at="$(date '+%H:%M')" || at="--:--"
  printf '%s %s\n' "$at" "$2" >>"$AIF_WORK_LOOP_LOGDIR/loop.log" 2>/dev/null || true
  if [ "${AIF_WORK_LOOP_TUI:-0}" = 1 ]; then
    ev="$(printf '%s|%s|%s\n%s\n' "$1" "$at" "$2" "$AIF_TUI_EVENTS" | sed -n '1,3p')" && AIF_TUI_EVENTS="$ev" || true
  elif [ "${AIF_WORK_LOOP_HUP:-0}" -eq 0 ]; then
    # Not once the terminal has closed: stderr is loop.log from then on, and
    # the line is there already, with its time.
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
# key (the key's read is the second); without, a wait. Neither may end the
# loop: under set -e a command a Ctrl-C ended would end the loop with it.
#
# Without the dashboard the second is spent in the `wait` builtin, on a
# `sleep 1` put in the background — never in a foreground `sleep 1`, which
# lost a Ctrl-C (docs/DEFECTS.md 11.1). bash 3.2 runs the INT trap for a
# foreground child only when the child died of the INT, or the INT came while
# the shell still waited for it; one that lands after waitpid returned and
# before the shell put its own handler back is noted in a flag nobody reads
# again. That is where a second Ctrl-C sent one tick after the first lands —
# handling the first started the tick again — and on this loop it was lost
# 10 times in 60, and 12 in 80 as the delay walked across the tick's end; the
# same Ctrl-Cs sent to a loop waiting in the builtin, none (docs/FINDINGS.md
# #33). A trapped signal that comes while the shell is inside `wait` makes the
# builtin return at once, over 128, and the trap runs once it has. The sleep
# ignores the INT — a background job of a script starts with it ignored
# (docs/FINDINGS.md #23) — so an interrupted wait leaves it running: it is
# ended here, by a TERM, which the loop traps, so the shell prints no notice
# of its death; one that is missed ends within the second. A HUP's handler
# runs after the builtin has put back its redirection, not inside it as in the
# dashboard's read (probed, #33), so its move of fd 2 to loop.log stands.
_aif_work_loop_tick() {
  local key="" tick rc=0
  if [ "${AIF_WORK_LOOP_TUI:-0}" != 1 ]; then
    sleep 1 &
    tick=$!
    wait "$tick" 2>/dev/null || rc=$?
    [ "$rc" -le 128 ] || kill -TERM "$tick" 2>/dev/null || true
    return 0
  fi
  _aif_work_loop_refresh
  _aif_work_loop_draw
  IFS= read -r -t 1 -n 1 -s key </dev/tty 2>/dev/null || true
  # A hang-up lands here nearly every time — the dashboard spends its
  # seconds in this read — and bash runs the trap INSIDE the read's own
  # redirections (docs/FINDINGS.md #28). The handler's `exec >>loop.log 2>&1`
  # moved fd 1 and fd 2; then the read returned and bash put back the fd 2 it
  # had saved for its `2>/dev/null` — the dead terminal. The next print to
  # it failed (EIO), errexit ended the loop with 1, and the bytes it could
  # not write, left in stdio's buffer, leaked into every `$(…)` after: the
  # summary's results were not JSON, no summary.json, and the loop lock's pid
  # read as `$$` plus text, so the lock stayed (docs/DEFECTS.md 14.8 — scenario
  # 48 ran with --no-tui, and never saw it). So the redirection is made again
  # here, once the read is done with its own.
  [ "${AIF_WORK_LOOP_HUP:-0}" -eq 0 ] || _aif_work_loop_to_log
  [ -z "$key" ] || _aif_work_loop_key "$key"
}

# _aif_work_loop_to_log — the loop's stdout and stderr to its own loop.log,
# or nowhere should even that fail, and whatever a failed print left in
# stdio's buffer thrown away: a print that succeeds flushes the buffer
# wherever it goes, and this one goes to /dev/null, not into a capture. What
# a hang-up leaves the loop (_aif_work_loop_signal HUP); every write is
# guarded, because errexit holds inside a trap.
_aif_work_loop_to_log() {
  exec >>"$AIF_WORK_LOOP_LOGDIR/loop.log" 2>&1 || exec >/dev/null 2>&1
  printf '\n' >/dev/null 2>&1 || true
}

# _aif_work_loop_refresh — what the frame shows: each worker's live state from
# its run lock, the cards in Ready it has not taken, the machine's load and
# free disk (every 10 seconds), and the selected worker's log when that is on
# screen.
#
# Ready is the loop's own read when that is fresh — it reads every poll while
# it has a slot free — and a read of the dashboard's own only once none has
# been made for a poll's length, which is when every slot is busy and the
# loop has no reason to look. One look per poll between them: on a Trello
# board each is a request, and an idle loop beside a shift is the board's
# steadiest client.
# The dashboard's state: read by lib/tui.sh, which a linter reading this file cannot see.
# shellcheck disable=SC2034
_aif_work_loop_refresh() {
  local i now lock id out="" l c
  now=$((AIF_WORK_LOOP_EPOCH + SECONDS))
  AIF_TUI_NOW="$now"
  for i in $(seq 1 "$AIF_TUI_PARALLEL"); do
    [ "${AIF_LS_RESULT[i]}" = running ] || continue
    lock="$AIF_WORK_LOOP_RUNS/${AIF_LS_ID[i]}"
    [ ! -f "$lock/live.json" ] || AIF_LS_LIVE[i]="$(cat "$lock/live.json" 2>/dev/null)" || true
  done
  if [ "$now" -ge $((${AIF_WORK_LOOP_READ_AT:-0} + ${AIF_WORK_LOOP_POLL_S:-30})) ]; then
    AIF_WORK_LOOP_READ_AT="$now"
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
    # The selected worker's own take: a card taken twice has a log a take.
    AIF_TUI_LOG="$(tail -n 6 "$AIF_WORK_LOOP_LOGDIR/${AIF_LS_LOG[AIF_TUI_SEL]:-${AIF_LS_ID[AIF_TUI_SEL]}.log}" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')" || AIF_TUI_LOG=""
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
  elif [ -n "${AIF_WORK_LOOP_PAUSED:-}" ]; then
    # The runner's limit: the workers wait, each box says until when (its
    # live.json's last), and no card is taken (docs/DEFECTS.md 13.7).
    AIF_TUI_STATUS="$AIF_WORK_LOOP_PAUSED · no new cards until then · q: end" AIF_TUI_STATUS_TONE=yellow
  elif [ "${AIF_WORK_LOOP_IDLE:-0}" = 1 ]; then
    # Idle is a state, not an end: said, with the cards it leaves in Ready —
    # and Ready not called empty while it holds them (docs/DEFECTS.md 15.3).
    AIF_TUI_STATUS="idle — ${AIF_WORK_LOOP_IDLE_WHY:-Ready is empty}; looking again every ${AIF_WORK_LOOP_POLL_S:-30}s · q: end${AIF_WORK_LOOP_HELD:+ · held: $AIF_WORK_LOOP_HELD}" AIF_TUI_STATUS_TONE=dim
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

# _aif_work_loop_signal <EXIT|INT|TERM|HUP> — the loop's handler, and what
# Ctrl-C means to a loop: the first takes no new card and lets the runs in
# flight finish; the second stops them, each settling its card as stopped by
# Ctrl-C. A TERM stops them at once. It records and forwards, and returns —
# the loop goes on from where the signal found it, waits for the runs, and
# says how each ended.
#
# A HUP — the terminal closed over the loop — stops them at once too, and has
# to: each run is a process group of its own, no job of the shell that hung
# up, so the hang-up never reaches it, and a loop that simply died of it left
# its workers building for nobody (docs/AUTOPILOT-RESEARCH.md §6.11,
# verification 2; docs/DEFECTS.md 14.8). They get the TERM a --stop sends —
# the signal every station is known to die of — and the loop itself ends in
# 129, so whoever started it can tell a closed window from a stop.
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
    HUP)
      # The terminal is gone, and the loop's stderr with it: from here every
      # print to it fails with EIO, and errexit holds inside a trap as it does
      # outside (bash 3.2, probed — the worker's handler guards its one print
      # for the same reason). This handler returns and the loop goes on, so
      # the first plain `_aif_work_say` after it — the "stopped (exit 143)"
      # of the very runs this branch stops, or the summary line when none
      # was running — would end the loop with the print's 1: no summary.json,
      # and a 1 where the 129 below was promised (docs/DEFECTS.md 14.8). So
      # the dashboard is left while its escape sequences can still be
      # swallowed, and the loop's output goes where its events already go,
      # its own loop.log — or nowhere, should even that fail: nothing after
      # this can end the loop for want of a terminal, and
      # `_aif_work_loop_tick` sleeps instead of reading keys, at once, from a
      # tty that is no longer there. When the hang-up lands inside the
      # dashboard's key read, the read undoes half of this on its way out;
      # the tick makes it again (_aif_work_loop_tick).
      _aif_work_loop_tui_stop 2>/dev/null || true
      AIF_WORK_LOOP_TUI=0
      _aif_work_loop_to_log
      AIF_WORK_LOOP_STOP="the terminal closed (HUP) — the runs in flight were stopped too"
      AIF_WORK_LOOP_HUP=1
      _aif_work_loop_forward TERM
      ;;
    EXIT)
      # The loop itself failing: the terminal back first; then the summary a
      # parent may be waiting for, unless the loop wrote it already — the
      # counts as they stand, read from the loop's own locals, which a handler
      # running inside its call sees (bash scopes dynamically; probed on 3.2),
      # the reason being whatever stopped it, or that nothing had yet; then
      # its workers — processes of their own, which go on, each settling its
      # own card. After a hang-up, its output to loop.log again, whatever a
      # builtin's redirection put back; and on every way here, what a print
      # that failed left in stdio's buffer thrown away before the captures
      # below read it as theirs (_aif_work_loop_to_log, docs/DEFECTS.md 14.8).
      if [ "${AIF_WORK_LOOP_HUP:-0}" -ne 0 ]; then
        _aif_work_loop_to_log
      else
        _aif_work_loop_tui_stop || true
        printf '\n' >/dev/null 2>&1 || true
      fi
      [ -z "${AIF_WORK_LOOP_LOGDIR:-}" ] || [ -f "$AIF_WORK_LOOP_LOGDIR/summary.json" ] ||
        _aif_work_loop_summary "$AIF_WORK_LOOP_LOGDIR/summary.json" "${taken_n:-0}" "${env:-0}" \
          "${AIF_WORK_LOOP_STOP:-${why:-the loop ended on an error before it could say why — its loop.log says where}}" "${results:-}" \
          "${idle:-0}" "${rechecks:-0}" "${AIF_WORK_LOOP_HELD:-}"
      # The checkout's loop lock goes with the loop, whatever ended it.
      _aif_work_loop_unlock || true
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

# _aif_work_loop_forget <ID> — the card leaves the loop's taken list.
_aif_work_loop_forget() {
  local t keep=" "
  for t in $AIF_WORK_LOOP_TAKEN; do
    [ "$t" = "$1" ] || keep="$keep$t "
  done
  AIF_WORK_LOOP_TAKEN="$keep"
}

# _aif_work_loop_prune <ready-ids> <idle 0|1> — after a Ready read that
# answered: AIF_WORK_LOOP_HELD names the cards the loop took that are still
# in Ready, and will not take again; and, idle, the taken list keeps what is
# running and what is still in Ready, and forgets the rest. A loop that is not
# idle takes each card once for its life, and names what it left in Ready the
# same way — in its summary, where "Ready is empty" used to stand over them.
#
# Without it an idle loop took each card once for the life of the loop, and
# the cards that come BACK to Ready are exactly the ones a loop meant to run
# all night must take again: a land that found its branch behind sends it
# back (sync:), a shift retries a card the environment blocked
# (docs/AUTOPILOT-RESEARCH.md §6.3, R16), a person moves one back once its
# trouble is fixed (docs/DEFECTS.md 13.8). A card that has left Ready
# and come back is new work. One that never left — its run exited and the
# card is still at the top — stays skipped, or the loop would take it again
# every poll; it is named as held, on the dashboard and in summary.json.
_aif_work_loop_prune() {
  local rl=" " running=" " id entry keep=" " held=""
  for id in $1; do
    rl="$rl$id "
  done
  for entry in $AIF_WORK_LOOP_RUNNING; do
    id="${entry#*:}"
    running="$running${id%%:*} "
  done
  for id in $AIF_WORK_LOOP_TAKEN; do
    case "$rl$running" in
      *" $id "*) keep="$keep$id " ;;
    esac
    case "$running" in
      *" $id "*) ;;
      *)
        case "$rl" in
          *" $id "*) held="${held:+$held }$id" ;;
        esac
        ;;
    esac
  done
  [ "${2:-1}" -eq 0 ] || AIF_WORK_LOOP_TAKEN="$keep"
  AIF_WORK_LOOP_HELD="$held"
}

# _aif_work_loop_idle_why <ready-ids> — what to say of a Ready this loop has
# nothing to take from, into AIF_WORK_LOOP_IDLE_WHY: empty; holding only
# cards it took and will not take again (AIF_WORK_LOOP_TAKEN, the held ones
# when idle); or holding cards workers elsewhere have (docs/DEFECTS.md 15.3).
_aif_work_loop_idle_why() {
  local id others=0 n=0
  for id in $1; do
    n=$((n + 1))
    case "$AIF_WORK_LOOP_TAKEN" in
      *" $id "*) ;;
      *) others=$((others + 1)) ;;
    esac
  done
  if [ "$n" -eq 0 ]; then
    AIF_WORK_LOOP_IDLE_WHY="Ready is empty"
  elif [ "$others" -eq 0 ]; then
    AIF_WORK_LOOP_IDLE_WHY="Ready holds only cards this loop will not take again"
  else
    AIF_WORK_LOOP_IDLE_WHY="Ready holds nothing this loop can take now"
  fi
}

# _aif_work_loop_pause — the shared pause (aif_pause_file), as the loop reads
# it at the top of every second: AIF_WORK_LOOP_PAUSED the line it says while
# the runner's limit pauses — said once a reset, the take skipped, the board
# not read — AIF_WORK_LOOP_PAUSE_HELD 1 while it holds past what a run waits
# (AIF_WORK_LOOP_HOLD_WHY the stop's reason), AIF_WORK_LOOP_PAUSE_OVER 1 once
# it has ended. Builtins only, on the loop's own clock: a `date` forks only
# when the reset changes, for the time a person reads (docs/DEFECTS.md 11.1,
# 13.7).
_aif_work_loop_pause() {
  local now hhmm
  AIF_WORK_LOOP_PAUSE_HELD=0
  now=$((AIF_WORK_LOOP_EPOCH + SECONDS))
  AIF_PAUSE_STATE=none
  ! _aif_work_pause_read "$AIF_WORK_LOOP_PAUSE_FILE" || _aif_work_pause_state "$now"
  case "$AIF_PAUSE_STATE" in
    paused)
      [ "$AIF_PAUSE_UNTIL" != "$AIF_WORK_LOOP_PAUSE_SEEN" ] || return 0
      AIF_WORK_LOOP_PAUSE_SEEN="$AIF_PAUSE_UNTIL"
      hhmm="$(_aif_work_when "$AIF_PAUSE_UNTIL")" || hhmm="?"
      _aif_work_limit_label "$AIF_PAUSE_TYPE"
      AIF_WORK_LOOP_PAUSED="paused until $hhmm — $AIF_LIMIT_LABEL, met by ${AIF_PAUSE_BY:-a worker}"
      _aif_work_loop_event yellow "$AIF_WORK_LOOP_PAUSED; no new card until then"
      ;;
    held)
      AIF_WORK_LOOP_PAUSE_HELD=1
      [ -z "$AIF_WORK_LOOP_HOLD_WHY" ] || return 0
      _aif_work_limit_label "$AIF_PAUSE_TYPE"
      if [ "$AIF_PAUSE_UNTIL" -eq 0 ]; then
        hhmm="no reset named"
      else
        hhmm="$(_aif_work_when "$AIF_PAUSE_UNTIL")" || hhmm="?"
        hhmm="resets $hhmm"
      fi
      AIF_WORK_LOOP_HOLD_WHY="the runner's usage limit ($AIF_LIMIT_LABEL): $hhmm — longer than the loop waits; no new card (rm .aif/state/pause to try anyway)"
      ;;
    *)
      [ -n "$AIF_WORK_LOOP_PAUSED" ] || return 0
      AIF_WORK_LOOP_PAUSED=""
      AIF_WORK_LOOP_PAUSE_SEEN=""
      AIF_WORK_LOOP_PAUSE_OVER=1
      _aif_work_loop_event green "the pause is over — taking cards again"
      ;;
  esac
  return 0
}

# _aif_work_loop_take_log <ID> — the log the worker about to take <ID>
# writes, a name in the loop's log directory, into AIF_WORK_LOOP_TAKE_LOG:
# <ID>.log the first time this loop takes it, <ID>.2.log the second, and so
# on. An idle loop takes a card again when it comes back — a land's sync:, a
# shift's retry, a person's move — and one log per card had the second
# worker's output written over the first's: why it stopped, the lines before
# a refusal, gone, and two results rows naming one file (docs/DEFECTS.md
# 15.7). Counts the take; a global, not printed — a `$(…)` would lose the
# count with its subshell.
_aif_work_loop_take_log() {
  local t n=1
  for t in $AIF_WORK_LOOP_TAKES; do
    [ "$t" != "$1" ] || n=$((n + 1))
  done
  AIF_WORK_LOOP_TAKES="$AIF_WORK_LOOP_TAKES$1 "
  if [ "$n" -eq 1 ]; then
    AIF_WORK_LOOP_TAKE_LOG="$1.log"
  else
    AIF_WORK_LOOP_TAKE_LOG="$1.$n.log"
  fi
}

# _aif_work_loop_why_set <ID> <why> — how <ID>'s last run here ended, in the
# words a held card is named with: one line a card in AIF_WORK_LOOP_WHYS,
# `<ID>|<why>`, the newest kept. One line however it was said: a why is read
# back a line at a time.
_aif_work_loop_why_set() {
  local keep="" line why="${2//$'\n'/ }"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "${line%%|*}" = "$1" ] || keep="$keep$line
"
  done <<EOF
$AIF_WORK_LOOP_WHYS
EOF
  AIF_WORK_LOOP_WHYS="$keep$1|$why
"
}

# _aif_work_loop_held_publish — the cards this loop holds, each with why, into
# its lock's owner.json as `held: [ { ticket, why } ]` whenever that changed
# (docs/DEFECTS.md 15.3). The loop remembered what it held and nothing outside
# the process could know: owner.json said nothing of it, and summary.json's
# `held` is written when the loop ends — so a shift in another terminal read
# a live idle loop and a Ready of cards that loop would never take as work in
# flight, and waited for it until the person pressed q. Rewritten whole, to a
# temp name and moved, like the logdir before it; not having written it costs
# the shift its line, not the loop its run.
_aif_work_loop_held_publish() {
  local lock="${AIF_WORK_LOOP_LOCK:-}" held
  [ -n "$lock" ] && [ -f "$lock/owner.json" ] || return 0
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  held="$(printf '%s' "$AIF_WORK_LOOP_WHYS" | jq -R -s -c --arg held "$AIF_WORK_LOOP_HELD" '
    (split("\n") | map(select(length > 0) | { key: split("|")[0], value: .[(index("|") + 1):] })
      | from_entries) as $w
    | [ $held | split(" ")[] | select(length > 0)
        | { ticket: ., why: ($w[.] // "its run here ended with the card still in Ready") } ]' 2>/dev/null)" || return 0
  [ -n "$held" ] && [ "$held" != "$AIF_WORK_LOOP_HELD_PUB" ] || return 0
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  if { jq --argjson h "$held" '.held = $h' "$lock/owner.json" >"$lock/owner.json.tmp" &&
    mv "$lock/owner.json.tmp" "$lock/owner.json"; } 2>/dev/null; then
    AIF_WORK_LOOP_HELD_PUB="$held"
  else
    rm -f "$lock/owner.json.tmp" 2>/dev/null || true
  fi
  return 0
}

# _aif_work_loop_stop_runs <who> — before the loop's TERM to its runs: a stop
# file in each one's run lock, the one `aif work <ID> --stop` writes, so each
# card says a person stopped it — `by <who> (aif work <ID> --stop), during
# <stage>` — and not `by a TERM signal`, which reads as a stop nobody meant
# and the one a shift may retry. Only into a lock the run itself signed: a
# worker that had not taken its lock yet has no card to speak for.
_aif_work_loop_stop_runs() {
  local entry pid id lock
  for entry in $AIF_WORK_LOOP_RUNNING; do
    pid="${entry%%:*}"
    id="${entry#*:}"
    id="${id%%:*}"
    lock="$AIF_WORK_LOOP_RUNS/$id"
    [ "$(_aif_work_lock_pid "$lock")" = "$pid" ] || continue
    printf '%s\n' "$1" >"$lock/stop" 2>/dev/null || true
  done
}

# _aif_work_loop_lock <root> <parallel> <idle> — take this checkout's loop lock,
# or say who holds it. rc 0 taken, AIF_WORK_LOOP_LOCK names it · 1 held, said.
#
# One loop per checkout (aif_loop_lock_dir, lib/paths.sh). A second used to
# start beside the first and read the same Ready, each worker it started
# refused by the other's run lock only once it was running — and a drain or a
# stop said to "the loop" reaches one of them. Taken before the preflight, so
# a second loop is refused before it probes the suite, and before the loop
# names its log directory: a refused loop given the same AIF_WORK_LOOP_LOGDIR
# must not remove the first one's summary.json on its way out
# (docs/DEFECTS.md 14.3). Taken the way the run lock and the shift lock are
# (_aif_work_lock_take): a dead lock taken over by one taker only, where it
# used to be `rm -rf` then `mkdir`, which two loops started in the same
# instant over a dead one both passed (docs/DEFECTS.md 14.5); its liveness
# matches `aif work … --loop`, not a worker and not the word.
# owner.json is what a shift in another terminal reads of the loop: its pid
# and host, since when, how many at once, whether it idles, where its logs
# and summary.json are — null until the loop has named the directory, after
# its preflight — and the cards it holds in Ready and will not take again,
# each with why (`held`, rewritten as that changes: docs/DEFECTS.md 15.3).
_aif_work_loop_lock() {
  local root="$1" parallel="$2" idle="$3" lock rc=0
  AIF_WORK_LOOP_LOCK=""
  lock="$(aif_loop_lock_dir "$root")"
  _aif_work_lock_take "$lock" '*aif\ work*--loop*' || rc=$?
  case "$rc" in
    0) ;;
    1)
      aif_err "a loop is already running on this checkout ($AIF_LOCK_HELD) — it takes the cards from Ready, and a second would race it. Stop it with Ctrl-C in its terminal, or: aif work --loop --stop"
      return 1
      ;;
    *)
      aif_err "a loop is already running on this checkout — another took its lock just now, and a second would race it"
      return 1
      ;;
  esac
  [ -z "$AIF_LOCK_DEAD" ] ||
    _aif_work_say "lock" "the loop that held this checkout (pid $AIF_LOCK_DEAD) is gone; taken over"
  # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
  if ! {
    jq -n --argjson pid "$$" --arg host "$(aif_host_short)" \
      --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --argjson started "$(date +%s)" \
      --argjson parallel "$parallel" --argjson idle "$idle" \
      '{ pid: $pid, host: $host, started_at: $at, started: $started,
         parallel: $parallel, idle: $idle, logdir: null, held: [] }' >"$lock/owner.json.tmp" &&
      mv "$lock/owner.json.tmp" "$lock/owner.json"
  } 2>/dev/null; then
    # Unsigned, the lock would read as live for a minute and then be taken
    # over; nothing has started, so it goes, and so does the loop.
    rm -rf "${lock:?}"
    aif_err "could not sign the loop lock at $lock — nothing was started"
    return 1
  fi
  AIF_WORK_LOOP_LOCK="$lock"
  return 0
}

# _aif_work_loop_unlock — release the loop lock, if this process holds it.
_aif_work_loop_unlock() {
  local lock="${AIF_WORK_LOOP_LOCK:-}"
  [ -n "$lock" ] || return 0
  AIF_WORK_LOOP_LOCK=""
  [ "$(_aif_work_lock_pid "$lock")" = "$$" ] || return 0
  rm -rf "${lock:?}" 2>/dev/null || true
}

# _aif_work_loop_early <EXIT|INT|TERM|HUP> — the handler between the loop lock
# and the loop's own (_aif_work_loop_signal replaces it): the preflight, which
# exits on every refusal, and its suite probe, which a Ctrl-C may end. Either
# way the lock goes with the process — left, it would say a loop runs here
# for as long as its pid stayed unused. An interrupt, a TERM and a hang-up end
# the process in 130, 143 and 129; an exit keeps its own code.
_aif_work_loop_early() {
  _aif_work_loop_unlock || true
  case "${1:-}" in
    INT) exit 130 ;;
    TERM) exit 143 ;;
    HUP) exit 129 ;;
  esac
  return 0
}

# _aif_work_loop_tell <root> <drain|stop> — `aif work --loop --drain` and `aif
# work --loop --stop`: tell the loop on this checkout, from any terminal, to
# take no new card — and, for a stop, to stop the runs in flight too, each
# card saying who.
#
# A file in the loop's lock, not a signal (docs/DEFECTS.md 11.1). A Ctrl-C
# reaches the loop from its own terminal only, and bash 3.2 can lose one
# that lands as the loop's tick ends; a second terminal, a shift, a person
# back at a laptop had no way to say "no more" that was sure to be heard.
# The loop reads these files every second, with builtins alone. Line 1 is
# who asked, as `aif work <ID> --stop` writes it.
#
# A drain answers at once: what is in flight finishes, which may take an hour.
# A stop waits up to 90 seconds for the loop to end — each run settles its
# card first — and then says what the loop's summary.json says. The log
# directory is read before the wait, and again while the loop is still in its
# preflight and has not named it: the lock it lives in goes with the loop.
#
# rc 0 told (drain) or stopped (stop) · 1 no loop to tell, or a stop that did
# not end it within 90 seconds.
_aif_work_loop_tell() {
  local root="$1" what="$2" lock pid who logdir l t0 why pg
  lock="$(aif_loop_lock_dir "$root")"
  if [ ! -d "$lock" ]; then
    aif_err "no loop is running on this checkout — nothing to $what"
    return 1
  fi
  pid="$(_aif_work_lock_pid "$lock")"
  if ! _aif_work_lock_live_as "$lock" '*aif\ work*--loop*'; then
    # Gone without its handler — kill -9, a reboot. Its lock refuses nobody
    # (the next loop takes it over) but says a loop runs here: it goes, unless
    # a new loop took it over while this looked.
    [ "$(_aif_work_lock_pid "$lock")" != "$pid" ] || rm -rf "${lock:?}"
    aif_err "no loop is running on this checkout — the one that held its lock (pid ${pid:-?}) is gone, and the lock it left is removed; nothing to $what"
    return 1
  fi
  if [ -z "$pid" ]; then
    aif_err "a loop took its lock a moment ago and has not signed it yet — run this again"
    return 1
  fi
  who="$(git -C "$root" config user.name 2>/dev/null || true)"
  [ -n "$who" ] || who="${USER:-someone}"
  logdir="$(jq -r '.logdir // empty' "$lock/owner.json" 2>/dev/null)" || logdir=""
  # Whole, then moved: the loop reads it the second it is there.
  if ! { printf '%s\n' "$who" >"$lock/$what.tmp" && mv "$lock/$what.tmp" "$lock/$what"; } 2>/dev/null; then
    rm -f "$lock/$what.tmp" 2>/dev/null || true
    if [ ! -d "$lock" ]; then
      aif_err "the loop (pid $pid) ended as this was said — nothing to $what"
    else
      aif_err "could not write into the loop's lock ($lock) — the loop was not told"
    fi
    return 1
  fi
  if [ "$what" = drain ]; then
    printf 'the loop (pid %s) takes no new card; the runs in flight finish\n' "$pid"
    return 0
  fi
  _aif_work_say "stop" "the loop (pid $pid) — no new card, and every run in flight stopped, each card saying who"
  # Still in its preflight — the loop names its log directory in its lock as
  # its first act after it, so none named is a loop that has not looked at
  # the file yet, and will not until its suite probe ends: the stop answered
  # "still running after 90 s" over a loop that stopped at its first look
  # (docs/DEFECTS.md 15.9). Nothing of a run to settle yet, so a TERM, which
  # the handler it has then (_aif_work_loop_early) answers by releasing the
  # lock and ending 143 — to its whole group when it leads one, as a loop
  # started from a terminal or by a shift does, so the probe it waits on ends
  # with it and the handler runs at once; else to the loop alone, whose
  # handler then runs once the probe is done (docs/FINDINGS.md #23).
  l="$(jq -r '.logdir // empty' "$lock/owner.json" 2>/dev/null)" || l=""
  if [ -z "$logdir" ] && [ -z "$l" ] && [ "$(_aif_work_lock_pid "$lock")" = "$pid" ]; then
    pg="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" || pg=""
    if [ "$pg" = "$pid" ]; then
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    else
      kill -TERM "$pid" 2>/dev/null || true
    fi
  fi
  logdir="${logdir:-$l}"
  t0="$(date +%s)"
  # Ended when its pid is gone, or its lock: the loop releases the lock once
  # its summary is written, a breath before it exits — and a pid its parent
  # has not reaped yet still answers kill -0 (probed: a zombie does, on
  # macOS), so a loop whose parent is busy would read as running the whole
  # 90 seconds.
  while kill -0 "$pid" 2>/dev/null && [ "$(_aif_work_lock_pid "$lock")" = "$pid" ]; do
    if [ $(($(date +%s) - t0)) -ge 90 ]; then
      aif_err "the loop (pid $pid) is still running after 90 s — its runs settle their own cards; run this again to see where it got to"
      return 1
    fi
    if [ -z "$logdir" ]; then
      l="$(jq -r '.logdir // empty' "$lock/owner.json" 2>/dev/null)" || l=""
      logdir="$l"
    fi
    sleep 0.2 2>/dev/null || sleep 1
  done
  if [ -z "$logdir" ]; then
    printf '%sstopped%s the loop (pid %s) — it stopped before taking a card\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$pid"
    return 0
  fi
  why="$(jq -r '.why // empty' "$logdir/summary.json" 2>/dev/null)" || why=""
  if [ -n "$why" ]; then
    printf '%sstopped%s the loop (pid %s) — %s\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$pid" "$why"
  else
    printf '%sstopped%s the loop (pid %s) — it wrote no summary; %s/loop.log says how it ended\n' "$AIF_C_GREEN" "$AIF_C_RESET" "$pid" "$logdir"
  fi
  return 0
}

aif_cmd_work() {
  local ticket="" profile="" budget="" max_minutes="" use_worktree=1 clean=0
  local loop=0 max_tickets=0 stop=0 parallel="" profile_arg tui=auto idle=0 drain=0
  # want_status, not status: the run's outcome below already has that name.
  local want_status=0 json=0
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
      --drain) drain=1 ;;
      --status) want_status=1 ;;
      --json) json=1 ;;
      --no-tui) tui=off ;;
      --loop) loop=1 ;;
      --idle) idle=1 ;;
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
  if [ "$use_worktree" -eq 0 ] && [ "$clean" -eq 0 ] && [ "$stop" -eq 0 ] && [ "$drain" -eq 0 ] &&
    [ "$want_status" -eq 0 ] && [ -z "${CI:-}" ] && [ "${AIF_DISPOSABLE:-}" != "1" ]; then
    aif_die "--no-worktree runs every station with bypassPermissions in THIS checkout, and nothing here says it is disposable. In CI, CI=1 already does; anywhere else: AIF_DISPOSABLE=1 aif work ${ticket:-<ticket>} --no-worktree"
  fi

  local root
  root="$(aif_require_project)"

  # What this machine knows of a run (_aif_work_status_json): read before
  # anything else, like a --stop — no profile, no board, no lock — and never
  # beside a flag that changes something, which it would not do.
  if [ "$want_status" -eq 1 ]; then
    [ "$loop" -eq 0 ] && [ "$clean" -eq 0 ] && [ "$stop" -eq 0 ] && [ "$drain" -eq 0 ] ||
      aif_die "--status reads what this machine knows of a run and changes nothing — not with --loop, --clean, --stop or --drain"
    [ "$idle" -eq 0 ] || aif_die "--idle only means something with --loop"
    # A path is built from the id: the characters a ticket id is made of.
    case "$ticket" in
      '') ;;
      [!A-Za-z0-9]* | *[!A-Za-z0-9._-]*) aif_die "not a ticket id: $ticket" ;;
    esac
    _aif_work_status "$root" "$ticket" "$json"
    return 0
  fi
  [ "$json" -eq 0 ] || aif_die "--json only means something with --status: aif work --status [<ticket>] --json"

  # The loop's own commands, for the loop on this checkout from any terminal
  # (_aif_work_loop_tell): before the profile and the preflight, like a run's
  # --stop, and taking no lock of their own. A drain or a stop of the loop is
  # said with --loop, never inferred from a missing ticket: `aif work --stop`
  # with the ID forgotten would otherwise stop every run in flight.
  if [ "$drain" -eq 1 ] || { [ "$stop" -eq 1 ] && [ "$loop" -eq 1 ] && [ -z "$ticket" ]; }; then
    [ "$loop" -eq 1 ] && [ -z "$ticket" ] ||
      aif_die "--drain is for the loop on this checkout: aif work --loop --drain"
    [ "$drain" -eq 0 ] || [ "$stop" -eq 0 ] ||
      aif_die "--drain lets the runs in flight finish and --stop stops them — one or the other"
    [ "$clean" -eq 0 ] ||
      aif_die "--clean removes one ticket's worktree — not with --loop --drain or --loop --stop"
    if [ "$drain" -eq 1 ]; then
      _aif_work_loop_tell "$root" drain && return 0
    else
      _aif_work_loop_tell "$root" stop && return 0
    fi
    exit 1
  fi
  [ "$idle" -eq 0 ] || [ "$loop" -eq 1 ] || aif_die "--idle only means something with --loop"

  if [ "$stop" -eq 1 ]; then
    [ -n "$ticket" ] || aif_die "usage: aif work <ticket> --stop — the loop: aif work --loop --stop"
    [ "$loop" -eq 0 ] && [ "$clean" -eq 0 ] ||
      aif_die "--stop with a ticket stops that one run and does nothing else — not with --loop or --clean (the loop's own: aif work --loop --stop)"
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
    # The checkout's loop lock first, then a handler that releases it on
    # every way out of the preflight (both above _aif_work_loop say why).
    _aif_work_loop_lock "$root" "$parallel" "$idle" || exit 3
    aif_trap_arm _aif_work_loop_early
    _aif_work_preflight "$root" "$profile"
    _aif_work_loop "$root" "$max_tickets" "$profile_arg" "$budget" "$budget_off" "$max_minutes" "$use_worktree" "$parallel" "$tui" \
      "$idle" "$profile"
  fi
  [ "$max_tickets" -eq 0 ] || aif_die "--max-tickets only means something with --loop"
  [ -z "$parallel" ] || aif_die "--parallel only means something with --loop"

  _aif_work_preflight "$root" "$profile"

  # What an earlier run of this machine could not say on a card, said now that
  # the board answers (docs/DEFECTS.md 14.2).
  _aif_work_repost_kept "$root"

  # No ticket named: the board decides. The top of Ready is the project
  # manager's order, and the worker consumes it — queue policy is theirs, the
  # queue is not. On Trello, past the cards another machine's live worker has
  # claimed (_aif_work_claim_check), each said.
  if [ -z "$ticket" ]; then
    if [ "$(aif_board_kind "$root")" = trello ]; then
      local cand cands
      cands="$(aif_board_ready_list "$root")"
      for cand in $cands; do
        if _aif_work_claim_check "$root" "$cand"; then
          ticket="$cand"
          break
        fi
        _aif_work_say "board" "$cand is taken on $AIF_WORK_CLAIMED — skipped"
      done
      [ -n "$ticket" ] || aif_die "nothing in the board's Ready column that another machine's worker has not claimed — write a ticket with /aif-ba, or name one: aif work <ticket>"
    else
      ticket="$(aif_board_next_ready "$root")"
      [ -n "$ticket" ] || aif_die "nothing in the board's Ready column — write a ticket with /aif-ba, or name one: aif work <ticket>"
    fi
    _aif_work_say "board" "next in Ready: $ticket"
  elif ! _aif_work_claim_check "$root" "$ticket"; then
    # The loop reads this line back (_aif_work_loop): a card another machine
    # builds is held, not the environment. Its words are fixed.
    aif_err "$ticket is taken on $AIF_WORK_CLAIMED — skipped: another machine's worker has it. Nothing was spent here, and its card was not touched"
    exit 3
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
  local lock_rc=0
  _aif_work_lock "$root" "$ticket" || lock_rc=$?
  if [ "$lock_rc" -eq 3 ]; then
    # Never a takeover into a tree an orphan edits (docs/DEFECTS.md 14.1).
    aif_err "$ticket's last worker is gone, and what it started still runs: $AIF_WORK_LOCK_HELD — not taken over. Nothing was spent, and its card was not touched. aif work --status $ticket lists it; once it has stopped, run this again"
    exit 3
  fi
  if [ "$lock_rc" -ne 0 ]; then
    aif_err "$ticket is being built by another worker on this machine ($AIF_WORK_LOCK_HELD). Nothing was spent, and its card was not touched. To stop that run: aif work $ticket --stop"
    exit 3
  fi
  # A land of this ticket borrows its worktree for its verdict, and moves the
  # card when it ends (lib/cmd_land.sh; docs/DEFECTS.md 15.1): a worker taking
  # the card meanwhile would build in the land's tree. Before the card moves,
  # with the run lock already held — the land refuses a ticket whose run lock
  # is live, so of two that start at once one always sees the other.
  if _aif_work_land_live "$root" "$ticket"; then
    _aif_work_unlock
    aif_err "aif land $ticket runs in this checkout right now (pid $AIF_WORK_LANDING) — its worktree is the land's until it ends. Nothing was spent, and its card was not touched; when the land is done, run this again"
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
  _aif_work_claim "$root" "$ticket"
  # Another machine that read the card before this one claimed it may have
  # moved it too: the earlier claim builds it, and this worker takes nothing —
  # its claim withdrawn, no worktree, the card left as the winner has it
  # (docs/DEFECTS.md 14.4). Its words are the claim check's, which the loop
  # reads back.
  if ! _aif_work_claim_race "$root" "$ticket"; then
    AIF_WORK_SETTLED=1
    aif_err "$ticket is taken on $AIF_WORK_CLAIMED — skipped: another machine's worker has it. It claimed the card a moment before this worker did, and both moved it to In Progress; this claim was withdrawn, nothing was spent here, and the card was left to it"
    exit 3
  fi

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
    # What the helper said on the way to a worktree is said here too, not only
    # on a failure: git's own output is silenced in it, so the lines are aif's —
    # above all that it added .aif/worktrees/ to the .gitignore block, which
    # leaves the developer's .gitignore modified (docs/DEFECTS.md 15.14).
    while IFS= read -r cut_why; do
      [ -z "$cut_why" ] || _aif_work_say "worktree" "$cut_why"
    done <"$cut_err"
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
  if [ "$intake_rc" -eq 4 ]; then
    # The takeover cap (docs/DEFECTS.md 14.5): the record says so too, so
    # that `aif work --status` reads a stopped run and not one still running.
    nr_why="taken over $AIF_WORK_TAKEOVERS times; its workers died the same way each time — read the run before another"
    # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags
    aif_run_update "$(aif_task_dir "$wt" "$ticket")" \
      '.status = "stopped" | .why = $why | .finished_at = $at' \
      --arg why "$nr_why" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || true
    _aif_work_block "$root" "$ticket" run "$nr_why" "" || true
    AIF_WORK_SETTLED=1
    exit 1
  fi
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
  # AIF_WORK_MAX_SECS — the harness's: the clock in seconds, over
  # --max-minutes, as AIF_WORK_LOOP_POLL is the loop's.
  AIF_WORK_MAX_SECS_SET=""
  case "${AIF_WORK_MAX_SECS:-}" in
    '' | *[!0-9]*) ;;
    *)
      run_max="$AIF_WORK_MAX_SECS"
      AIF_WORK_MAX_SECS_SET=1
      ;;
  esac
  started="$(date +%s)"
  # The wall clock, for the one question every dispatch asks of it
  # (_aif_work_clock_past): the seconds waited on the runner are counted
  # apart and left out of it (docs/DEFECTS.md 13.7).
  AIF_WORK_CLOCK_START="$started"
  AIF_WORK_CLOCK_MAX="$run_max"
  AIF_WORK_PAUSED_SECS=0

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
    if _aif_work_clock_past; then
      status="stopped"
      why="$(_aif_work_clock_why)"
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
            AIF_WORK_CLOCK_START="$started"
            AIF_WORK_PAUSED_SECS=0
            continue
          fi
          status="stopped"
          why="$AIF_WORK_REBUILD_WHY"
          break
          ;;
        4)
          status="stopped"
          why="$AIF_WORK_SYNC_WHY"
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
      # The stage this dispatch counted an attempt of: a handler that runs
      # while the dispatch waits on the runner takes it back, since nothing
      # was judged (_aif_work_abandon).
      AIF_WORK_COUNTED="$stage"
      AIF_WORK_DISPATCH_VIA=stage AIF_WORK_DISPATCH_ATTEMPT="$((attempts + 1))"
      _aif_work_dispatch "$wt" "$ticket" "$stage" "$agent" "$complaint" \
        "$budget_left" "$out" || rc=$?
      AIF_WORK_COUNTED="" AIF_WORK_DISPATCH_VIA="" AIF_WORK_DISPATCH_ATTEMPT=""
      # What the tries the runner cut off cost — a limit's refused call, a
      # throttled one — is spent too, whatever the dispatch came to.
      spent="$(awk -v s="$spent" -v c="${AIF_WORK_DISPATCH_EXTRA:-0}" 'BEGIN { printf "%.4f", s + c }')"
      if [ "$rc" -eq 3 ] || [ "$rc" -eq 4 ]; then
        rm -f "$out"
        # Nothing was judged: the attempt is not one (docs/DEFECTS.md 13.7).
        # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags below
        aif_run_update "$work" '.attempts[$s] = ([((.attempts[$s] // 1) - 1), 0] | max) | .spent_usd = $sp' \
          --arg s "$stage" --argjson sp "$spent" || true
        status="stopped"
        if [ "$rc" -eq 3 ]; then
          why="${AIF_WORK_DISPATCH_WHY:-the runner could not run the $stage station — the environment, not the ticket.}"
        else
          why="$(_aif_work_clock_why)"
        fi
        break
      fi
      _aif_work_keep_envelope "$wt" "$ticket" "$dispatches" "$stage" "$out"
      spent="$(awk -v s="$spent" -v c="$(_aif_work_envelope_cost "$wt" "$out")" 'BEGIN { printf "%.4f", s + c }')"
      # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags below
      aif_run_update "$work" '.spent_usd = $s' --argjson s "$spent"
      if ! "aif_runner_${AIF_PROFILE_RUNNER}_result_ok" "$out"; then
        # Guarded: a read that fails is no reason for the worker to die here
        # under set -e — it did, with code 5, on an envelope that was not JSON
        # (docs/DEFECTS.md 13.7).
        station_err="$("aif_runner_${AIF_PROFILE_RUNNER}_result_error" "$out")" ||
          station_err="the runner's envelope could not be read"
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
        # The tree green just admitted the implementation on — the suite and
        # the checks bound to it — sealed by the commit above: `judged`, the
        # verdict the land takes instead of judging that same tree again
        # (lib/cmd_land.sh _aif_land_worker_verdict; docs/DEFECTS.md 13.5).
        # shellcheck disable=SC2016  # jq's variables, bound by the --arg flags below
        aif_run_update "$work" '.stage = $n | (if $s == "implement" and $h != "" then .judged = $h else . end)' \
          --arg n "$(aif_run_next "$stage")" --arg s "$stage" --arg h "$(git -C "$wt" rev-parse -q --verify HEAD 2>/dev/null || true)"
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
    # analyst's. Whatever else stopped the run is the run's — unless the last
    # dispatch ended on the runner, whatever called it (the stage loop, a
    # repair, a sync): its usage limit past what a run waits, or no answer
    # after every backoff. That is the environment, and the loop that reads
    # this line asks the machine again instead of counting the card toward
    # two in a row (docs/DEFECTS.md 13.8, 13.7). The flag is set again at
    # every dispatch, so only the last one's end says it.
    kind=run
    [ "$status" != "spec" ] || kind=ticket
    [ "${AIF_WORK_RUNNER_ENV:-0}" != 1 ] || kind=environment
    headline="$(printf '%s\n' "$why" | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^[[:space:]]*$' | sed -n 1p)" || headline=""
    [ -n "$headline" ] || headline="the run stopped at $(aif_run_get "$work" '.stage')"
    _aif_work_block "$root" "$ticket" "$kind" "$headline" "$report_path" "$full_at" || true
  fi
  AIF_WORK_SETTLED=1
  [ "$status" = "built" ]
}
