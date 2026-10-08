# lib/start.jq — the shift's oracle (`aif start`): the facts of one tick in,
# the plan out. Run as `jq -f "$AIF_ROOT/lib/start.jq" <facts.json>`
# (_aif_start_oracle, lib/cmd_start.sh); not sourced, not executed.
#
# Why a file of its own, and not a single-quoted program inside the shell like
# every other jq here: this one is a few hundred lines of policy, and inside a
# single-quoted shell string one apostrophe — in a comment, where nobody looks —
# ends the quote and breaks the whole file a hundred lines later
# (docs/FINDINGS.md "jq programs embedded in shell"). A file is also what makes
# the policy testable on its own: `jq -f lib/start.jq fixture.json` runs any
# row of it over a hand-written fixture, with no board, no model and no
# terminal. The tap installs the whole of lib/ (`libexec.install "bin", "lib"`),
# so the file travels with the code that runs it.
#
# A PURE function. Everything it decides on is in the facts document
# (_aif_start_facts: the board, this machine, the repository, the shift's own
# memory); nothing here reads a clock, a file or the environment. The rows are
# docs/AUTOPILOT-RESEARCH.md §6.3 (R2–R21) as docs/AUTOPILOT-PHASE1.md cluster
# E corrected them against the code and the probes.
#
# The plan:
#
#   { counts: { backlog, ready, in_progress, review, needs_human, done },
#     moves:  [ { rule, key, ticket, column, kind, from, to, where, file,
#                 comment, text } ],
#     units:  [ { rule, key, kind, ticket, file, column, role, prompt, name,
#                 default, keys, text, warn, kill, comment, to, top } ],
#     lines:  [ { rule, ticket, file, column, text, command } ],
#     wait:   null | { why },
#     "end":  null | { rc, why } }
#
# moves are bash's to make without asking (comment first, then move; where
# says where a comment's body comes from: "branch" or "checkout" for the run's
# report.md, "file" for a blocked: comment kept in `file`); units are offered
# one per tick at the control point, in this order; lines are what the shift
# will not touch, each with the command that would; wait is work in flight
# elsewhere that the shift waits for; end ends it. Never an end beside a move:
# the driver makes the moves and decides on the next tick. Read `end` as
# ."end" — a keyword, which jq before 1.7 does not take as a bare key.
#
# Keys are the fact, not the card (research R24: once a shift, without
# hiding what is new). A row keyed on a head carries that head's time, a row
# keyed on a run its run's finish, so a second verdict or a second build is a
# new key and is offered again, while the same fact read twice is not. A
# move or unit whose key the driver has recorded (memory.done) is left out
# and becomes a line, with what the driver noted and the command that does it
# by hand — nothing offered once disappears from the plan, or from the
# summary that prints the lines.
#
# jq 1.6 is the floor here as bash 3.2 is in the shell: no keyword as a bare
# object key, no `if` without `else`, nothing newer than 1.6 in the library.

# A value as it goes into a key: null and the empty string read "-".
def nz: if . == null or . == "" then "-" else tostring end;

# How many items at the front of an array satisfy f.
def leading(f): if length == 0 then 0 elif (.[0] | f) then 1 + (.[1:] | leading(f)) else 0 end;

# A request named as a ticket names it — requests/x.md, ./requests/x.md,
# x.md, x — down to the slug they share (lib/requests.sh compares the same way).
def slug: tostring | split("/") | last | sub("\\.md$"; "");

# The three entry shapes, every field present and null where it means nothing
# for that entry, so a reader never tests for a key. `type` is dropped on the
# way out.
def move($rule; $key; $c; $kind; $to; $text):
  { type: "move", rule: $rule, key: $key, ticket: $c.ticket, column: $c.column, kind: $kind,
    from: $c.column, to: $to, where: null, file: null, comment: null, text: $text };
def unit($rule; $key; $kind; $text):
  { type: "unit", rule: $rule, key: $key, kind: $kind, ticket: null, file: null, column: null,
    role: null, prompt: null, name: null, default: "open", keys: {}, text: $text,
    warn: null, kill: null, comment: null, to: null, top: false };
def session($rule; $key; $role; $prompt; $name; $text):
  unit($rule; $key; "session"; $text) + { role: $role, prompt: $prompt, name: $name };
def line($rule; $c; $text; $cmd):
  { type: "line", rule: $rule, ticket: $c.ticket, file: null, column: $c.column, text: $text, command: $cmd };

# On a card: the key of a row decided by its head — the rule, the card, and
# the time of the head it was decided on.
def hkey($rule): "\($rule) \(.ticket) \(.head.at | nz)";

# An ISO UTC time as epoch seconds (Trello's milliseconds taken off), or null
# for anything else — a fixture's "t1" included.
def epoch: if type == "string" then (try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null) else null end;

# On a card: the NEWEST `taken:` claim among its heads — host, pid and time as
# the worker wrote them (`taken: <host> pid <pid> at <ISO> — aif work`,
# lib/cmd_work.sh _aif_work_claim), the time the board gave the comment, and
# when its worker last said it was alive (`· alive at <ISO>`, the heartbeat
# it edits into that first line at every dispatch, docs/DEFECTS.md 14.4) —
# or null when no take is on it. A claim another machine withdrew after a
# race (`not taken: …`) is no head, and so no claim.
def claim:
  ([ (.head.heads // [])[] | select((.line // "") | startswith("taken: ")) ] | last) as $t
  | if $t == null then null
    else (($t.line | capture("^taken: (?<host>[^ ]+) pid (?<pid>[0-9]+) at (?<at>[^ ]+)"))
          // { host: null, pid: null, at: null })
         + { head_at: $t.at, alive: (($t.line | capture(" · alive at (?<a>[^ ]+)$") | .a) // null) }
    end;

# On a claim: the epoch of the last time its worker said it was alive — the
# heartbeat, else the time the claim names, else the comment's own — or null.
def claim_life: [ (.alive | epoch), (.at | epoch), (.head_at | epoch) ] | map(select(. != null)) | max;

# On a card: the first of the hold labels it carries, or null. A person put it
# aside (lib/release.sh, AIF_RELEASE_HOLD_LABELS): it gets a line, never a move.
def held($holds): first((.labels // [])[] as $l | $holds[] | select(. == $l)) // null;

. as $f
| ($f.host // "") as $host
| (($f.board_kind // "local") == "trello") as $trello
| ($f.hold_labels // []) as $holds
| ($f.memory.done // []) as $done
| ($f.flags // {}) as $flags
| ($f.build // {}) as $b
| ($b.mode // "here") as $mode
| ($b.parallel // 2) as $par
| ($f.cards // []) as $cards
| ($f.requests // []) as $reqs
# The runner's usage limit as a worker of this checkout left it
# (lib/cmd_work.sh _aif_work_pause_json): paused — it resets within what a run
# waits — or held, past that or with no reset named. While either holds no
# session and no build is offered, each of which would meet it at once; a
# pause is waited out, as work in flight is, and a hold with nothing else to
# do ends the shift on the environment, naming when to come back
# (docs/DEFECTS.md 13.7).
| (($f.pause // null) | if type == "object" and (.state == "paused" or .state == "held") then . else null end) as $pause
| (($pause // {}).state // "") as $pstate
| (if $pause == null then ""
   else "the runner's usage limit (\($pause.label // "a limit"))"
        + (if $pstate == "paused" then " until \($pause.until_hhmm // "its reset")"
           elif $pause.until_hhmm != null then ": resets \($pause.until_hhmm), longer than a run waits"
           else ": no reset named" end) end) as $pausesay

# One column, in the board's order.
| def col($k): [ $cards[] | select(.column == $k) ] | sort_by(.pos);
  def count($k): [ $cards[] | select(.column == $k) ] | length;

  # On a move or unit: the driver recorded its key — offered, acted on,
  # skipped or failed once this shift.
  def isdone: .key as $k | any($done[]; .key == $k);
  def live_of: [ .[] | select(isdone | not) ];

  # On a move or unit left out for its key: the line it becomes. Its text is
  # what the driver noted when it recorded the key; its command what does it
  # by hand.
  #
  # The bare `aif board move` only for a move that is nothing but the move. A
  # requeue the shift refused — a station of the dead worker still running,
  # an `s`, a board that said no — is the move R3b exists to hold back while
  # that station edits the worktree (docs/DEFECTS.md 14.1): printed bare, the
  # person runs it beside an idle loop and the next worker dispatches into
  # that tree; `aif work --status` says first what still runs. A rework: or a
  # cancelled: moved without its comment leaves a card the analyst never
  # reads (the BA list takes rework: heads only) — the project manager, as the
  # summary names it for a move never tried. A report's move without its
  # report, and a blocked: move without its line, lose what the card was
  # supposed to say: the run's own state says where that is. The rest carry
  # a `released by aif start:` line that only says the shift moved the card —
  # a pull, an answer, a retry — and a person who moves it is that line: the
  # bare move, and the driver's note has the comment it kept, with the two
  # commands that finish it as the shift meant (_aif_start_comment_move).
  def as_line:
    .key as $k
    | ((first($done[] | select(.key == $k) | .note) // "") | if . == "" then "offered once this shift" else . end) as $note
    | { type: "line", rule: .rule, ticket: .ticket, file: .file, column: .column, text: $note,
        command: (if .kind == "session" then "claude '\(.prompt)'"
                  elif .kind == "land" then "aif land \(.ticket)"
                  elif .kind == "demo" then "claude '/aif-pjm \(.ticket)'"
                  elif .kind == "sweep" then "aif board release"
                  elif .kind == "build" then "aif work --loop --parallel \($par)"
                  elif .kind == "requeue" then "aif work --status \(.ticket)"
                  elif .kind == "rework" or .kind == "cancel" then "claude '/aif-pjm \(.ticket)'"
                  elif (.kind == "report" or .kind == "blocked") and (.comment != null or .where != null)
                  then "aif work --status \(.ticket)"
                  elif .ticket != null and .to != null
                  then "aif board move \(.ticket) \(.to)" + (if .top == true then " --top" else "" end)
                  else null end) };
  def done_lines: [ .[] | select(isdone) | as_line ];

  # A card whose head could not be read this tick: a line, and nothing decided
  # on it — an unread head is never an empty one (research R1; DEFECTS 14.7).
  # It is work in flight, waited for, until its head failed three looks in a
  # row (`unread_looks`, counted by the facts): a board that never answers for
  # one card kept the shift waiting on it until q, its line the only word of
  # why (docs/DEFECTS.md 15.9). Past that it is a line the shift does not wait
  # on — still nothing decided on it.
  def gave_up: .unread == true and (.unread_looks // 0) >= 3;
  def unread_line:
    if gave_up then
      line("R1"; .; "its comments could not be read for \(.unread_looks) looks in a row — \(.unread_why // "the card could not be read"); the shift does not wait on it"; "aif board head \(.ticket)")
    else
      line("R1"; .; "not read — \(.unread_why // "the card could not be read")"; "aif board head \(.ticket)")
    end;

# ------------------------------------------------------------ In Progress
#
# A card here with no live worker behind it on this machine is one of three
# things (maps: lock-run.md §C): built, with only its report or its move lost
# (R3a, a move); killed mid-station, with nothing settled (R3b, a requeue at
# the control point, its orphans stopped first); or stopped, with only the
# move to Needs Human lost (R3c, a move — never Ready: lib/cmd_work.sh, "never
# put back in Ready behind anyone's back").

  # R3b: back to the top of Ready, where a loop resumes it. `kill` is what the
  # dead worker left running (lib/cmd_work.sh _aif_work_status_orphans: by its
  # group, its station's pid or this clone's worktree — a station of another
  # clone building the same id is not this card's, docs/DEFECTS.md 15.4), each
  # row flagged `group` only when its group is the dead worker's own — the
  # pgid is the lock's pid, and that pid is gone: a pid alive under another
  # command belongs to some other program, and so does its group
  # (docs/DEFECTS.md 14.1; critics operations-3). `$stale`: the branch holds a
  # build of a round before the newest take, which died before its intake.
  def requeue($c; $l; $stale):
    ($l.lock // {}) as $k
    | (if $k.pid == null then "" else " (pid \($k.pid))" end) as $pp
    | ($k.phase // "") as $ph
    | ($ph == "claim" or $ph == "worktree" or $ph == "intake") as $early
    | (if $early then $ph else ($k.stage // $l.run.stage // "its run") end) as $at
    | (if $k.attempt == null then "" else ", attempt \($k.attempt)" end) as $att
    # No record: `aif work --status` always says `run`, its fields null when
    # there is none — read as a run still going, a dead lock with no record
    # and no phase was "gone mid-its run" and resumed "from its run".
    | ($l.run == null or ($l.run.status // null) == null) as $norec
    | ($stale or $norec or $early or $l.run.status == "built") as $over
    # A lock with no phase file says nothing of where its worker died — the
    # phase is written right after the lock is taken (docs/DEFECTS.md 15.9).
    | (if $stale or $l.run.status == "built" then "gone before its intake"
       elif $norec and $ph == "" then "gone, its phase unknown, before its intake"
       elif $norec or $early then "gone during its \($ph), before its intake"
       else "gone mid-\($at)\($att)" end) as $gone
    | (if $stale or $l.run.status == "built"
       then " (the build on branch aif/\($c.ticket) is of a round before)" else "" end) as $old
    | (if $over then "back to the top of Ready, where a loop builds it from the start"
       else "back to the top of Ready, where a loop resumes it from \($at)" end) as $back
    # Only what is proved the dead run's is stopped: its group, its station.
    # A process tied to it by nothing but a working directory inside the
    # worktree may be a person's shell or editor opened there, and it used to
    # be TERMed with the rest: it is named, never signalled, and the card
    # stays while it runs — the next worker would dispatch into a tree it is
    # in, as the takeover refuses to (lib/cmd_work.sh _aif_work_lock_orphans;
    # docs/DEFECTS.md 14.1).
    | [ ($k.orphans // [])[] | select(.why != "cwd") | . + { group: (.pgid == $k.pid and $k.pid_alive != true) } ] as $kill
    | [ ($k.orphans // [])[] | select(.why == "cwd") ] as $keep
    | ($kill | length) as $n
    | ($keep | length) as $m
    | ([ $keep[] | "pid \(.pid) (\((.command // "") | .[0:60]))" ] | join(", ")) as $kept
    | if $m > 0 and $n == 0 then
        line("R3b"; $c;
             "its worker\($pp) is \($gone)\($old), and \($kept) \(if $m == 1 then "runs" else "run" end) in its worktree — nothing but the directory ties \(if $m == 1 then "it" else "them" end) to the run, so the shift stops nothing and requeues nothing while \(if $m == 1 then "it runs" else "they run" end)";
             "aif work --status \($c.ticket)")
      else
        unit("R3b"; "R3b \($c.ticket) \(($k.started // $k.started_at) | nz)"; "requeue";
             "requeue \($c.ticket) — its worker\($pp) is \($gone)\($old); \($back)"
             + (if $n == 0 then ""
                else " · \($n) process\(if $n == 1 then "" else "es" end) it left running, stopped first" end)
             + (if $m == 0 then ""
                else " · \($kept) in its worktree, never stopped — not requeued while \(if $m == 1 then "it runs" else "they run" end)" end))
        + { ticket: $c.ticket, column: $c.column, default: "go", to: "ready", top: true, kill: $kill, keep: $keep,
            comment: "released by aif start: its worker\($pp) was \($gone), with no process left behind it — \($back)" }
      end;

  def ip_entries:
    . as $c
    | $c.local as $l
    | ($c | claim) as $cl
    | ($l.lock // {}) as $k
    | if $c.unread == true then [ $c | unread_line ]
      elif $l == null then
        [ line("R2"; $c; "what this machine knows of its run could not be read"; "aif work --status \($c.ticket)") ]
      # R2: being built here — counted, shown, never signalled.
      elif $l.class == "live" then
        [ line("R2"; $c;
               (if $k.pid == null then "a worker took its lock here a moment ago"
                else "being built here (pid \($k.pid), \($k.stage // $k.phase // "its claim")"
                     + (if $k.attempt == null then "" else " attempt \($k.attempt)" end) + ")" end);
               null) ]
      # A shared board: only a card whose newest take names this machine is
      # this machine's to move (docs/DEFECTS.md 14.4; critics operations-9).
      # Its worker beats on the claim at every dispatch; a claim silent for
      # longer than a run can last, and ten minutes more, is a worker likely
      # gone — said with what finds out, never a move: the run lock that
      # knows is on that machine.
      elif $trello and $cl != null and $cl.host != $host then
        ($cl | claim_life) as $life
        | ($f.wall_clock_min // 120) as $wall
        | if $life != null and (($f.now // null) | type) == "number" and ($f.now - $life) > ($wall + 10) * 60 then
            [ line("R4"; $c;
                   "taken by \($cl.host // "?") pid \($cl.pid // "?") at \($cl.at // $cl.head_at // "?") — its worker has said nothing for \((($f.now - $life) / 60) | floor) min, past the wall clock of a run (\($wall) min) and ten more: likely gone. On \($cl.host // "that machine"): aif work --status \($c.ticket); once nothing runs it there, back to Ready from here";
                   "aif board move \($c.ticket) ready") ]
          else
            [ line("R4"; $c; "taken by \($cl.host // "?") pid \($cl.pid // "?") at \($cl.at // $cl.head_at // "?") — built there; nothing to do here"; null) ]
          end
      # R4: nothing of it here — another machine, or a worker gone before it
      # wrote anything.
      elif $l.class == "none" or $l.class == "no_record" then
        [ line("R4"; $c; $l.why; "aif board move \($c.ticket) ready") ]
      elif $trello and $cl == null then
        [ line("R4"; $c; "no taken: line on the card says which machine took it, so the shift moves nothing — here: \($l.why)";
               "aif work --status \($c.ticket)") ]
      # R3a, unless the build is older than the newest take: a stale build of
      # the round before, whose new round died before its intake committed a
      # record (critics operations-8). The take's own time is the worker's
      # clock, the same clock as the run's finish; the comment's is the
      # board's, the fallback.
      elif $l.class == "built" then
        ($l.run.branch_finished_at // $l.run.finished_at) as $fin
        | ($cl.at // $cl.head_at) as $take
        | if $take != null and $fin != null and $fin < $take then
            (if $k.held == true and $k.live != true then [ requeue($c; $l; true) ]
             else [ line("R3a"; $c; "the build on branch aif/\($c.ticket) (\($fin)) is older than its newest take (\($take)) — a stale build of an earlier round, and no worker on it here";
                         "aif work \($c.ticket)") ] end)
          elif ($c.head.line // "") == "# \($c.ticket) — built" then
            [ move("R3a"; "R3a \($c.ticket) \($fin | nz)"; $c; "report"; "review";
                   "built here; its report is on the card, the move to Review was lost") ]
          else
            [ move("R3a"; "R3a \($c.ticket) \($fin | nz)"; $c; "report"; "review";
                   "built here; its report did not reach the card — posted from its \(if $l.run.where == "checkout" then "checkout" else "branch" end)")
              + { where: (if $l.run.where == "checkout" then "checkout" else "branch" end) } ]
          end
      elif $l.class == "built_uncommitted" then
        [ line("R3a"; $c; $l.why; "aif work \($c.ticket)") ]
      elif $l.class == "interrupted" then [ requeue($c; $l; false) ]
      # R3c: the comment as the worker meant it — kept in its file when the
      # board refused it (fresh: no older than this run), recomposed when the
      # card says only `taken:`, nothing when it already says why.
      elif $l.class == "stopped" or $l.class == "spec" or $l.class == "settled_running" then
        (if $l.class == "spec" then "ticket" else "run" end) as $kind
        | ($c.head.line // "") as $h
        | ($l.run.why_head
           // (if $l.run.status == "built" and $trello
               then "the build on branch aif/\($c.ticket) is of the card's text before it changed"
               elif $l.run.status == "built"
               then "the build on branch aif/\($c.ticket) is of the ticket before its rework"
               else "the run stopped at \($l.run.stage // "its run")" end)) as $why
        | [ move("R3c"; "R3c \($c.ticket) \(($l.run.branch_finished_at // $l.run.finished_at // $l.run.started_at) | nz)";
                 $c; "blocked"; "needs_human";
                 (if $l.class == "spec" then "its run stopped on the ticket here"
                  elif $l.class == "stopped" then "its run stopped here"
                  else "its worker settled it on the way out" end)
                 + "; only the move to Needs Human was lost — never back to Ready")
            + (if ($h | startswith("blocked: ")) then {}
               elif $l.blocked_file.fresh == true then { where: "file", file: $l.blocked_file.path }
               else { comment: "blocked: \($kind) — \($why)",
                      where: (if $l.report.head == null then null
                              elif $l.run.where == "checkout" then "checkout" else "branch" end) } end) ]
      else [ line("R4"; $c; ($l.why // "its run is in no state the shift knows"); "aif work --status \($c.ticket)") ]
      end;

# ----------------------------------------------------------------- Review
#
# Routed on the newest head, as the project manager routes it
# (sets/claude/skills/aif-pjm/SKILL.md): the verdicts bash can read are moves
# (R5) or keys (R5d, R6), a build is a review session (R7), and a person's
# words bash cannot read go to the project manager (R9). A move a role or a
# land half-made — its comment posted, its move lost — is finished, not
# listed (critics operations-16).

  # R8 for a card whose head says built: why `aif land` would refuse it, in
  # land's own words (lib/cmd_land.sh), or why the shift will not open a
  # review of it.
  def r8_built($c):
    $c.local as $l
    | if $l == null then line("R8"; $c; "what this machine knows of its run could not be read"; "aif work --status \($c.ticket)")
      elif $l.class == "live" then
        line("R8"; $c; "a worker is taking it here" + (if $l.lock.pid == null then "" else " (pid \($l.lock.pid))" end); null)
      elif $l.branch.exists != true then
        (if $l.run.where == "checkout"
         then line("R8"; $c; "built with --no-worktree — there is no branch aif/\($c.ticket) for aif land to take"; null)
         else line("R8"; $c; "no branch aif/\($c.ticket) — nothing was built for \($c.ticket) (aif work \($c.ticket))"; "aif work \($c.ticket)") end)
      elif $l.class == "built_uncommitted" then line("R8"; $c; $l.why; "aif work \($c.ticket)")
      # On Trello the card is the ticket, and the facts hash it as the pull
      # writes it (docs/DEFECTS.md 15.12): a person who edited the card after
      # its build gets no review of the build of the text before.
      elif $l.run.ticket_changed == true and $trello then
        line("R8"; $c; "the card changed after this build — a land would merge the build of its earlier text; aif work \($c.ticket) builds it again"; "aif work \($c.ticket)")
      elif $l.run.ticket_changed == true then
        line("R8"; $c; "the ticket changed after this build — a land would merge the build of the ticket before; aif work \($c.ticket) builds it again"; "aif work \($c.ticket)")
      elif ($l.run.branch_status // null) != "built" then
        line("R8"; $c; "the run on aif/\($c.ticket) did not end built (status: \($l.run.branch_status // "no run record")) — nothing to land"; "aif work \($c.ticket)")
      else line("R8"; $c; $l.why; null) end;

  def r8_other($c):
    ($c.head.line // "") as $h
    | if ($h | startswith("land: ")) then line("R8"; $c; "\($h) — the land was refused, or landed nothing"; "aif land \($c.ticket)")
      elif $h == "# \($c.ticket) — landed" then
        line("R8"; $c; "\($h) — but no aif: land \($c.ticket) commit in this checkout; landed from another?"; null)
      elif ($h | startswith("taken: ")) then r8_built($c)
      else line("R8"; $c; "\($h) — nothing the shift acts on"; null) end;

  # R9: words under the head that bash cannot read — the project manager reads
  # them, in a session of its own (or a line, --no-pjm).
  def r9($c):
    (if $c.head.line == null then "the card" else "\"\($c.head.line)\"" end) as $under
    | if $flags.pjm != false then
        [ session("R9"; ($c | hkey("R9")); "pjm"; "/aif-pjm \($c.ticket)"; "aif pjm \($c.ticket)";
                  "pjm \($c.ticket) — a person wrote under \($under)")
          + { ticket: $c.ticket, column: $c.column } ]
      else
        [ line("R9"; $c; "a person wrote under \($under) — \($c.head.after) comment\(if $c.head.after == 1 then "" else "s" end) the project manager reads";
               "claude '/aif-pjm \($c.ticket)'") ]
      end;

  def rv_entries:
    . as $c
    | ($c.head.line // null) as $h
    | ($c.head.body // "") as $body
    | (if ($body | test("[^[:space:]]")) then "\n" + $body else "" end) as $tail
    | $c.local as $l
    | if $c.unread == true then [ $c | unread_line ]
      elif $h == null then
        (if ($c.head.after // 0) > 0 then r9($c) else [ line("R8"; $c; "no aif line on the card — nothing the shift acts on"; null) ] end)
      # R5, as the project manager does it: the review's words, prefix and all
      # but the prefix, are the analyst's rework.
      elif ($h | startswith("wrong: ")) then
        [ move("R5"; ($c | hkey("R5")); $c; "rework"; "backlog"; "the review said wrong: — back to the analyst as rework:")
          + { comment: ("rework: " + ($h | ltrimstr("wrong: ")) + $tail) } ]
      elif ($h | startswith("cancel: ")) then
        [ move("R5"; ($c | hkey("R5")); $c; "cancel"; "done"; "the review cancelled it — to Done, nothing merged")
          + { comment: ("cancelled: " + ($h | ltrimstr("cancel: "))) } ]
      # R5d: the demo is advisory (aif-review SKILL.md) — rework by default,
      # `l` lands it over the demo.
      elif ($h | startswith("demo: not as expected")) then
        ($h | sub("^demo: not as expected( — )?"; "")) as $gap
        | [ unit("R5d"; ($c | hkey("R5d")); "demo";
                 "demo \($c.ticket) — not as expected" + (if $gap == "" then "" else ": \($gap)" end))
            + { ticket: $c.ticket, column: $c.column, default: "rework", keys: { l: "land" }, to: "backlog",
                comment: ("rework: " + (if $gap == "" then "the demo found the build not as expected" else $gap end) + $tail) } ]
      # R6: the review left the yes to the human; the default is to leave it.
      elif ($h | startswith("demo: as expected")) then
        [ unit("R6"; ($c | hkey("R6")); "land"; "land \($c.ticket) — the demo says as expected")
          + { ticket: $c.ticket, column: $c.column, default: "skip" } ]
      # R7, and R25 as its warning: a land refuses while files its branch
      # changes are uncommitted here — those, and no others (lib/cmd_land.sh;
      # docs/DEFECTS.md 13.5) — so a review that ends in one would be refused.
      elif $h == "# \($c.ticket) — built" then
        (if $l != null and $l.class == "built" and $l.branch.exists == true and $l.lock.live != true then
           [ session("R7"; ($c | hkey("R7")); "review"; "/aif-review \($c.ticket)"; "aif review \($c.ticket)";
                     "review \($c.ticket) — built, branch aif/\($c.ticket)")
             + { ticket: $c.ticket, column: $c.column,
                 warn: (($c.land_dirty // []) as $ld
                        | if ($ld | length) == 0 then null
                          else "aif land will refuse while these files it changes are uncommitted: \($ld | join(", ")) — commit or stash them first" end) } ]
         else [ r8_built($c) ] end)
      # Half-made moves, finished.
      elif ($h | startswith("rework: ")) then
        [ move("R5"; ($c | hkey("R5")); $c; "finish"; "backlog"; "its rework: line is on it, the move to Backlog was lost") ]
      elif ($h | startswith("cancelled: ")) then
        [ move("R5"; ($c | hkey("R5")); $c; "finish"; "done"; "its cancelled: line is on it, the move to Done was lost") ]
      elif $h == "# \($c.ticket) — landed" and $c.land_commit == true then
        [ move("R6"; ($c | hkey("R6")); $c; "finish"; "done"; "landed here, the move to Done was lost") ]
      elif ($h | startswith("taken: ")) and $l != null and $l.class == "built" then
        [ move("R3a"; "R3a \($c.ticket) \(($l.run.branch_finished_at // $l.run.finished_at) | nz)"; $c; "report"; "review";
               "built here; its report did not reach the card — posted from its \(if $l.run.where == "checkout" then "checkout" else "branch" end)")
          + { where: (if $l.run.where == "checkout" then "checkout" else "branch" end) } ]
      elif ($c.head.after // 0) > 0 then r9($c)
      else [ r8_other($c) ]
      end;

# ------------------------------------------------------------ Needs Human

  # R16: a block by the environment during this shift is retried once — the
  # driver runs one preflight for every such card of the tick. Per card, and
  # never an end here: two cards blocked by one hiccup are two retries, and a
  # card blocked again after its retry is a line (critics operations-12).
  #
  # "During": the head's time is the board's clock and the shift's start this
  # machine's, so a block posted in the shift's first seconds by a clock a
  # little behind read as one from before the shift, never retried — or one
  # from just before, by a clock ahead, as new. The head counts from
  # fresh_margin_s (120) before the start (docs/DEFECTS.md 15.6): a block in
  # the two minutes before a shift is retried once too, the cheaper mistake.
  # A time that is not one (a fixture's) is compared as the string it is.
  def r16($c):
    (($c.head.at | epoch) as $h | ($f.shift_started_at | epoch) as $s
     | if $h != null and $s != null then $h >= $s - ($f.fresh_margin_s // 0)
       else ($c.head.at // "") >= ($f.shift_started_at // "") end) as $fresh
    | any(($f.memory.retried_env // [])[]; . == $c.ticket) as $again
    | ($c.head.line | ltrimstr("blocked: environment — ")) as $why
    # A block by the runner's usage limit is retried once the limit is over,
    # not while it holds: the retry would meet it at its first station
    # (docs/DEFECTS.md 13.7).
    | if $fresh and ($again | not) and $pause != null and ($why | startswith("the runner's usage limit")) then
        [ line("R16"; $c; "blocked by the runner's usage limit during this shift — \($why); not retried while that limit holds";
               "aif board move \($c.ticket) ready") ]
      elif $fresh and ($again | not) then
        [ move("R16"; ($c | hkey("R16")); $c; "env-retry"; "ready";
               "blocked by the environment during this shift — retried once, if the preflight passes again")
          + { comment: "released by aif start: blocked by the environment during this shift; the preflight passes again — retried once" } ]
      elif $fresh then
        [ line("R16"; $c; "blocked by the environment again after its retry this shift — \($why)"; "aif board move \($c.ticket) ready") ]
      else
        [ line("R16"; $c; "blocked by the environment before this shift — \($why); once the machine is fixed"; "aif board move \($c.ticket) ready") ]
      end;

  # R17: a run or a stop is the human's (the project manager's table), unless
  # --retry-runs, once a card a shift, and only for what the instruments did:
  # never a cap, a rejection, a person's Ctrl-C or --stop. `was already gone`
  # is tested first — that text carries `--stop` too. The bounce count skips
  # the `taken:` and `released by aif` heads that sit between every two
  # blocks on a real card, or it could never reach two (critics operations-6).
  def r17($c):
    $c.head.line as $h
    | ($h | startswith("blocked: run — ")) as $isrun
    | ($h | sub("^blocked: (run|stopped) — "; "")) as $why
    | (if $isrun then
         ((($why | startswith("wall clock:")) or ($why | startswith("dispatch cap:"))
           or ($why | contains("rejected")) or ($why | contains("same complaint"))) | not)
       elif ($why | contains("was already gone")) then true
       elif ($why | contains(" --stop)")) or ($why | startswith("by Ctrl-C")) then false
       elif ($why | contains("by a TERM signal")) or ($why | contains("by a hang-up")) then true
       else false end) as $retriable
    | ([ ($c.head.heads // [])[] | (.line // "")
         | select((startswith("taken: ") or startswith("released by aif ")) | not) ]
       | reverse | leading(test("^blocked: (run|stopped) — "))) as $bounces
    | any(($f.memory.retried_run // [])[]; . == $c.ticket) as $again
    | if $flags.retry_runs == true and ($again | not) and $retriable and $bounces < 2 then
        [ move("R17"; ($c | hkey("R17")); $c; "retry-run"; "ready"; "\($why) — retried once (--retry-runs)")
          + { comment: "released by aif start: \($why) — retried once (--retry-runs)" } ]
      else
        [ line("R17"; $c;
               $h + (if $flags.retry_runs != true then ""
                     elif $again then " · retried once this shift already"
                     elif ($retriable | not) then
                       (if $isrun then " · not retried: a cap or a rejection is for a person"
                        else " · not retried: a person stopped it" end)
                     else " · not retried: blocked \($bounces) times in a row" end);
               "aif board move \($c.ticket) ready") ]
      end;

  def nh_entries:
    . as $c
    | ($c.head.line // null) as $h
    | ($c | held($holds)) as $lab
    | ($c | claim) as $cl
    | if $c.unread == true then [ $c | unread_line ]
      elif $lab != null then [ line("R18"; $c; "held: label \($lab)"; null) ]
      # The analyst's, through the BA list (R19b) — nothing here.
      elif $h != null and ($h | startswith("blocked: ticket — ")) then []
      # R18a: a person's words under the block are the readable "unblocked".
      elif $h != null and ($h | startswith("blocked: ")) and ($c.head.after // 0) > 0 then
        [ unit("R18a"; ($c | hkey("R18a")); "answered"; "answered \($c.ticket) — a person wrote under \"\($h)\"")
          + { ticket: $c.ticket, column: $c.column, default: "skip", keys: { r: "ready" }, to: "ready",
              comment: "released by aif start: a person answered under the blocked: line" } ]
      # A shared board: a block another machine's worker posted is that
      # machine's to retry, as In Progress is (docs/DEFECTS.md 14.4). R16's
      # "the preflight passes again" is this machine's preflight, which says
      # nothing of the machine whose environment blocked it; a retry here
      # only hands that machine's loop one more failed run toward its stop.
      elif $trello and $h != null and $cl != null and $cl.host != $host
           and (($h | startswith("blocked: environment — ")) or ($h | startswith("blocked: run — "))
                or ($h | startswith("blocked: stopped — "))) then
        [ line((if ($h | startswith("blocked: environment — ")) then "R16" else "R17" end); $c;
               "\($h) — blocked on \($cl.host // "?"), not here: that machine's to retry";
               "aif board move \($c.ticket) ready") ]
      elif $h != null and ($h | startswith("blocked: environment — ")) then r16($c)
      elif $h != null and (($h | startswith("blocked: run — ")) or ($h | startswith("blocked: stopped — "))) then r17($c)
      # The blocked: line the board refused, kept on this machine
      # (lib/cmd_work.sh _aif_work_block), posted now that the board answers
      # — a move that does not move, its comment the file: the card is where
      # it belongs, and only its first line was missing (docs/DEFECTS.md
      # 14.2). Only over this run's own claim, or nothing: any other head
      # since means the card moved on, and the file is stale.
      elif $c.kept_block != null
           and ($h == null or (($h | startswith("taken: ")) and ($cl == null or $cl.host == $host))) then
        [ move("R18"; "R18k \($c.ticket) \($c.head.at | nz)"; $c; "blocked"; "needs_human";
               "its blocked: line, refused by the board when it was blocked, kept on this machine — posted now; the card stays in Needs Human")
          + { where: "file", file: $c.kept_block.path } ]
      # R18: the rest is the human's, with the command its comment names. A
      # card here with no blocked: line is real (docs/DEFECTS.md 14.2): the
      # move went through and the comment did not.
      elif $h == null then
        [ line("R18"; $c; "no blocked: line on the card — the comment that says why did not reach it"; "aif work --status \($c.ticket)") ]
      elif ($h | startswith("land: ")) or $h == "# \($c.ticket) — not landed" then
        [ line("R18"; $c; $h; "aif board move \($c.ticket) review && aif land \($c.ticket)") ]
      elif ($h | startswith("taken: ")) then
        [ line("R18"; $c; "its blocked: line did not reach the card — the machine that took it keeps it in .aif/tmp/blocked-\($c.ticket).md";
               "aif work --status \($c.ticket)") ]
      else [ line("R18"; $c; $h; null) ]
      end;

# ---------------------------------------------------------------- Backlog
#
# Two kinds of card leave Backlog by the shift's rules: a slice whose every
# dependency landed (R10, through the sweep, which judges each again), and a
# card with no dependency whose ready gate passes, pulled on a key (R14). Any
# head holds a card, as the sweep holds it (lib/release.sh); a rework: card is
# the analyst's (R19a).

  def releasable:
    .unread != true and (.head.line // null) == null and held($holds) == null and .ticket_file == true
    and ((.meta.depends_on // []) | length) > 0
    and all((.deps // [])[]; .column == "done" and .landed == true);

  def pullable:
    .unread != true and (.head.line // null) == null and held($holds) == null and .ticket_file == true
    and ((.meta.depends_on // []) | length) == 0;

  # What the sweep would say of a card that waits, and its command when there
  # is one to give.
  def waits($c):
    first(($c.deps // [])[] | select((.column == "done" and .landed == true) | not)) as $d
    | if $d.column == null then [ "waits on \($d.ticket) (no card on the board)", null ]
      elif $d.column != "done" then [ "waits on \($d.ticket) (\($d.column))", null ]
      else [ "waits on \($d.ticket) (Done, but no \"aif: land \($d.ticket)\" commit here — merged by hand? then: aif board move \($c.ticket) ready)",
             "aif board move \($c.ticket) ready" ] end;

  def bl_entries:
    . as $c
    | ($c.head.line // null) as $h
    | ($c | held($holds)) as $lab
    | if $c.unread == true then [ $c | unread_line ]
      elif $lab != null then [ line("R10"; $c; "held: label \($lab)"; null) ]
      elif $h != null and ($h | startswith("rework: ")) then []
      # A release whose comment was posted and whose move was lost.
      elif $h != null and ($h | startswith("released by aif ")) then
        [ line("R10"; $c; "\($h) — the move to Ready was lost"; "aif board move \($c.ticket) ready") ]
      elif $h != null then [ line("R10"; $c; "held: \($h)"; null) ]
      elif $c.ticket_file != true then [ line("R10"; $c; "no tasks/\($c.ticket)/ticket.md in this checkout"; null) ]
      elif (($c.meta.depends_on // []) | length) > 0 then
        (if ($c | releasable) then [] else (waits($c)) as $w | [ line("R10"; $c; $w[0]; $w[1]) ] end)
      elif $c.ready_gate == 1 then [ line("R14"; $c; "its ready gate does not pass"; "aif _ready \($c.ticket)") ]
      # 3 is the environment, never "not ready" (docs/DEFECTS.md 15.9): a
      # gate not installed here is aif init's to put back; one that could
      # not run says what it lacks through aif _ready.
      elif $c.ready_gate == 3 and $f.ready_gate_installed == false then
        [ line("R14"; $c; "the ready gate could not run — it is not installed here; aif init installs it"; "aif init") ]
      elif $c.ready_gate == 3 then
        [ line("R14"; $c; "the ready gate could not run — the environment, not the ticket; aif _ready \($c.ticket) says what it lacks"; "aif _ready \($c.ticket)") ]
      elif $c.ready_gate != null and $c.ready_gate != 0 then
        [ line("R14"; $c; "its ready gate could not run (rc \($c.ready_gate))"; "aif _ready \($c.ticket)") ]
      else [] end;

# ------------------------------------------------------- the rows, gathered

  { backlog: count("backlog"), ready: count("ready"), in_progress: count("in_progress"),
    review: count("review"), needs_human: count("needs_human"), done: count("done") } as $counts
| ([ $cards[] | select(.unread == true) | select(gave_up | not) ] | length) as $unread
| ([ col("in_progress")[] | select(.local.class == "live") ] | length) as $building
| [ col("in_progress")[] | ip_entries[] ] as $ip
| [ col("review")[] | rv_entries[] ] as $rv
| [ col("needs_human")[] | nh_entries[] ] as $nh
| [ col("backlog")[] | bl_entries[] ] as $bl

# R10: one sweep for every slice it would release; the sweep checks each again
# and posts its own comment.
| [ col("backlog")[] | select(releasable) | .ticket ] as $rel
| ($rel | sort) as $relids
| (if ($relids | length) == 0 then []
   else [ { type: "move", rule: "R10", key: "R10 \($relids | join(" "))", ticket: null, column: "backlog",
            kind: "sweep", from: "backlog", to: "ready", where: null, file: null, comment: null,
            text: "\($relids | join(", ")) — every ticket \(if ($relids | length) == 1 then "it depends" else "they depend" end) on is Done and landed; the sweep releases \(if ($relids | length) == 1 then "it" else "them" end) to the bottom of Ready" } ] end) as $r10

# -------------------------------------------------------------- the BA list
#
# R19, one session at a time, in this order: (a) Backlog cards the review sent
# back as rework: — after the owner's session on the request when the demo
# said the request itself let the build through (R20); (b) Needs Human
# blocked: ticket (research R15 asked for an empty Ready first — dropped: with
# a loop in another terminal Ready is rarely empty, and these cards hold the
# slices behind them); then, only while the queue is short — Ready, In
# Progress and what the sweep would release under three rounds of the build —
# (c) a ticket begun and never cut, (d) a request cut in part, (e) a request
# not cut, or the owner first for a request in the older one-section shape.

| def po_seed($file; $sha; $why):
    session("R20"; "R20 \($file) \($sha | nz)"; "po"; "/aif-po \($file)"; "aif po \($file | slug)"; "owner \($file) — \($why)")
    + { file: $file };
  def req_sha($file): first($reqs[] | select(.slug == ($file | slug)) | .sha) // null;

  [ col("backlog")[] | select(.unread != true) | select(held($holds) == null)
    | select((.head.line // "") | startswith("rework: "))
    | . as $c
    | ((($c.head.body // "") | split("\n") | any(.[]; startswith("- request: "))) and $c.meta.request != null) as $seed
    # Keyed on the rework: line, not on the request: the owner's session
    # rewrites the request — that is its job — and a key on its sha made
    # each rewrite a new fact, the owner offered again ahead of the analyst
    # after every edit, by default. A new rework: is a new fact; the owner's
    # edits are not.
    | (if $seed then [ po_seed($c.meta.request; req_sha($c.meta.request);
                               "the demo says the request itself let the build through; the owner reworks it first")
                       + { key: ($c | hkey("R20")) } ]
       else [] end)
      + [ session("R19a"; ($c | hkey("R19a")); "ba"; "/aif-ba \($c.ticket)"; "aif ba \($c.ticket)"; "analyst \($c.ticket) — \($c.head.line)")
          + { ticket: $c.ticket, column: $c.column } ]
    | .[] ] as $ba_a
| [ col("needs_human")[] | select(.unread != true) | select(held($holds) == null)
    | select((.head.line // "") | startswith("blocked: ticket — "))
    | session("R19b"; hkey("R19b"); "ba"; "/aif-ba \(.ticket)"; "aif ba \(.ticket)"; "analyst \(.ticket) — \(.head.line)")
      + { ticket: .ticket, column: .column } ] as $ba_b
| ((($counts.ready + $counts.in_progress + ($rel | length)) < (3 * $par))) as $short
# (c): all three of — still the scaffold, never committed, never landed. On
# Trello a Done card archived away looks like a ticket with no card; it is
# committed and landed, and nobody's to cut again.
| [ ($f.loose_tasks // [])[] | select(.stub == true and .tracked != true and .landed != true)
    | session("R19c"; "R19c \(.ticket)"; "ba";
              (if .request != null and .slice != null then "/aif-ba \(.request) slice \(.slice) \(.ticket)" else "/aif-ba \(.ticket)" end);
              "aif ba \(.ticket)"; "analyst \(.ticket) — begun with aif _ticket-init and never cut; no card")
      + { ticket: .ticket } ] as $ba_c
# A committed ticket that aif never landed and that has no card is, on a board
# older than aif land, most often one built before it and archived when done
# (the first dry run on opes listed one): the command is offered only for the
# case where it still needs building, and the text says so.
| [ ($f.loose_tasks // [])[] | select(.stub != true and .landed != true)
    | { type: "line", rule: "R19c", ticket: .ticket, file: null, column: null,
        text: (if .tracked == true
               then "committed, never landed by aif land, no card on the board — built before aif land, or its card archived? only if it still needs building"
               else "a ticket with no card on the board" end),
        command: "aif board create tasks/\(.ticket)/ticket.md --column ready" } ] as $loose_lines
| [ $reqs[] | select(.effective == "cut in part")
    | session("R19d"; "R19d \(.file) \(.next_slice | nz) \(.sha | nz)"; "ba";
              (if .next_slice == null then "/aif-ba \(.file)" else "/aif-ba \(.file) slice \(.next_slice)" end);
              "aif ba \(.slug)";
              "analyst \(.file) — cut in part" + (if .next_slice == null then "" else "; slice \(.next_slice) of \(.slices) has no ticket" end))
      + { file: .file } ] as $ba_d
# (e): a request with no slices to cut — the older `## Scope` with no
# `## Status`, or neither section — goes to the owner first (research §4.6).
| [ $reqs[] | select(.effective == "not cut")
    | if ((.shape == "scope" and .status_line == "none") or .shape == "none") and ((.tickets // []) | length) == 0 then
        po_seed(.file; .sha;
                (if .shape == "scope" then "an older request, a Scope and no Status; the owner cuts it into slices first"
                 else "no Slices and no Scope yet; the owner writes them first" end))
      else
        session("R19e"; "R19e \(.file) \(.sha | nz)"; "ba"; "/aif-ba \(.file)"; "aif ba \(.slug)"; "analyst \(.file) — not cut")
        + { file: .file }
      end ] as $ba_e
| ($ba_a + $ba_b + (if $short then $ba_c + $ba_d + $ba_e else [] end)) as $ba
| ($ba | live_of) as $ba_live

# ----------------------------------------------------------- build and pull
#
# R12: the loop in this terminal, when this shift builds (mode here), its build
# not held, Ready not empty, and no Review unit ahead of it — and when Ready
# holds fewer than one round, one BA session first. R14: pulls, only while the
# BA list is empty, up to the build's free slots: in mode here Ready short of
# a round; in mode elsewhere the loop's whole load, Ready and the cards it
# builds — an idle loop keeps Ready at 0 exactly when it could take more
# (critics operations-11).

| [ $ip[] | select(.type == "unit") ] as $u_ip
| [ $rv[] | select(.type == "unit") ] as $u_rv
| [ $nh[] | select(.type == "unit") ] as $u_nh
| ($u_rv | live_of) as $rv_live
| $counts.ready as $ready
| ([ col("ready")[] | .ticket ] | sort) as $readyids
# R12 is keyed on each card's entry into Ready, not on the ids alone: the
# commonest round trip of a shift in this terminal — built, `wrong:` at the
# review, rework: to the analyst, back in Ready — rebuilds the same set of
# ids, and a key of ids alone read the reworked card as the build already
# done and ended the shift with it unbuilt. A card's moved_at moves on every
# move and create (lib/board.sh). On Trello it is the card's last activity,
# which a comment moves too, so the facts give each Ready card its `entry`:
# the moved_at it had when the shift first saw it in Ready, kept while it
# stays there — a comment on a card the loop left in Ready offered the build
# again, a loop that took nothing new (docs/DEFECTS.md 15.9). A card the loop
# left in Ready keeps the key: the same Ready is never offered twice
# (docs/AUTOPILOT-PHASE1.md G §6). _aif_start_build_now makes the same key.
| ([ col("ready")[] | "\(.ticket)@\((.entry // .moved_at) | nz)" ] | sort) as $readykeys
# The cards a loop in another terminal holds — it took each, the run ended
# with the card still in Ready, and it will not take it again (lib/cmd_work.sh
# _aif_work_loop_held_publish) — are not its load: the wait and the pulls
# leave them out, and each is a line with what moves it. Counted as Ready the
# loop would take, they made the shift wait on them for good (docs/DEFECTS.md
# 15.3).
| (if $mode == "elsewhere" then [ ($b.loop.held // [])[] | select(type == "object" and .ticket != null) ] else [] end) as $loopheld
| [ col("ready")[] | . as $c | first($loopheld[] | select(.ticket == $c.ticket)) as $h
    | { c: $c, why: ($h.why // "its run there ended with the card still in Ready") } ] as $heldready
| ($ready - ($heldready | length)) as $ready_loop
| (if $mode == "here" then (if $ready >= 1 and $ready < $par then $par - $ready else 0 end)
   elif $mode == "elsewhere" then $par - ($ready_loop + $building)
   else 0 end) as $free
# R13, the build held (two runs in a row that did not build, a stop or a
# drain, a loop that ended 1 or 143, or never started): never again on its
# own — but a unit, "build again", its default to leave it and Enter or b to
# build. It was a line, and with no unit, no move and nothing in flight the
# shift ended, Ready still holding cards and the b its line named never
# offered (docs/DEFECTS.md 15.8). Keyed as R12 is: passed by, it is a line
# with aif work --loop and the shift may end; a Ready that changed offers it
# again.
| (if $mode == "here" and $ready >= 1 and ($rv_live | length) == 0 then
     (if $b.hold == null then
        [ unit("R12"; "R12 \($readykeys | join(" "))"; "build";
               "build — Ready holds \($ready): \($readyids | join(", ")); the loop runs in this terminal, \($par) at once")
          + { column: "ready", default: "go" } ]
      else
        [ unit("R13"; "R13 \($readykeys | join(" "))"; "build";
               "build again — the build is held: \($b.hold); Ready holds \($ready): \($readyids | join(", "))")
          + { column: "ready", default: "skip" } ]
      end)
   else [] end) as $u12
| ($u12 | live_of) as $u12_live
| (($u12_live | length) > 0 and $ready < $par and ($ba_live | length) > 0) as $ba_first
| (if $free >= 1 and ($ba_live | length) == 0 then
     [ col("backlog")[] | select(pullable) | select(.ready_gate == 0)
       | unit("R14"; "R14 \(.ticket)"; "pull"; "pull \(.ticket) — no depends_on, and its ready gate passes; to the bottom of Ready")
         + { ticket: .ticket, column: .column, default: "skip", keys: { y: "pull" }, to: "ready",
             comment: "released by aif start: pulled from Backlog at the shift's control point — it has no depends_on and its ready gate passes" } ]
   else [] end) as $u14
| (if $free >= 1 then $u14 | live_of | .[0:$free] else [] end) as $u14_live
# The held build is a line only while a review is offered ahead of it.
| ((if $mode == "here" and $b.hold != null and $ready >= 1 and ($rv_live | length) > 0 then
      [ { type: "line", rule: "R13", ticket: null, file: null, column: "ready",
          text: "the build is held: \($b.hold) — b at the control point builds again", command: null } ]
    elif $mode == "none" and $ready >= 1 then
      [ { type: "line", rule: "R12", ticket: null, file: null, column: "ready",
          text: "Ready holds \($ready) — no loop runs on this checkout", command: "aif work --loop --idle" } ]
    else [] end)
   + [ $heldready[] | line("R12"; .c; "the loop in another terminal will not take it again — \(.why); aif work \(.c.ticket), or restart the loop";
                           "aif work \(.c.ticket)") ]
   # The build the runner's limit holds back (below): said, with Ready.
   + (if $pause != null and ($u12_live | length) > 0 then
        [ { type: "line", rule: "R12", ticket: null, file: null, column: "ready",
            text: "no build while \($pausesay) — Ready holds \($ready)", command: null } ]
      else [] end)) as $l12

# ---------------------------------------------------------------- the plan

| ([ ($ip + $rv + $nh + $bl + $r10)[] | select(.type == "move") ]) as $moves_all
| ($moves_all | live_of) as $moves
| ((($u_ip | live_of) + $rv_live + ($u_nh | live_of)
    + (if $ba_first then [ $ba_live[0] ] else [] end)
    + $u14_live + $u12_live
    + (if $ba_first then $ba_live[1:] else $ba_live end))
   # The runner's limit holds: no session, no build (above, $pause). Moves,
   # pulls, requeues and lands do not call the runner, and go on.
   | if $pause == null then . else [ .[] | select(.kind != "session" and .kind != "build") ] end) as $units0
# Work in flight is waited for, never an end: a card built here now, a loop in
# another terminal with Ready to take, a card not read yet (critics
# operations-1). R21 only when none of it is left. Under --no-build with no
# loop yet, Ready is work in flight too: the person said the loop runs in
# another terminal, and the usage starts the shift first — an end there said
# "nothing left" and "bring a need" while Ready held the cards, before the
# second terminal was open, and under --po opened the owner on that premise.
# The shift waits, naming the command, and takes the loop up as `elsewhere`
# once it starts.
| (($moves | length) == 0 and ($units0 | length) == 0) as $idle
# Ready the loop elsewhere would take — never the cards it holds (above).
| ($building > 0 or (($mode == "elsewhere" or $mode == "none") and $ready_loop >= 1) or $unread > 0
   or $pstate == "paused") as $inflight
| (if $idle and ($inflight | not) and $flags.po == true and $pause == null then
     [ session("R21"; "R21"; "po"; "/aif-po"; "aif po"; "owner — nothing left on the board; bring a need") ]
   else [] end) as $u21
| ($units0 + ($u21 | live_of)) as $units
# The lines in the board's order: each column's own, with what was left out
# for its key where its card is; then the rest.
| ([ $ip[], $rv[], $nh[], $bl[] | if .type == "line" then . elif isdone then as_line else empty end ]
   + $loose_lines + $l12
   + (($r10 + $u14 + $u12 + $ba + $u21) | done_lines)) as $lines
| { counts: $counts,
    moves: [ $moves[] | del(.type) ],
    units: [ $units[] | del(.type) ],
    lines: [ $lines[] | del(.type) ],
    wait: (if $idle and $inflight then
             { why: (([ (if $building > 0 then "\($building) being built" else empty end),
                        (if ($mode == "elsewhere" or $mode == "none") and $ready_loop >= 1 then "\($ready_loop) in Ready" else empty end),
                        (if $unread > 0 then "\($unread) card\(if $unread == 1 then "" else "s" end) not read yet" else empty end),
                        (if $pstate == "paused" then "\($pausesay) — no session and no build until then" else empty end) ]
                      | join(", "))
                     + (if $mode == "elsewhere"
                        then " — the loop in another terminal" + (if $b.loop.pid == null then "" else " (pid \($b.loop.pid))" end)
                        elif $mode == "none" and $ready_loop >= 1
                        then " — no loop runs on this checkout yet: aif work --loop --idle in another terminal"
                        else "" end)) }
           else null end),
    "end": (if $idle and ($inflight | not) and ($units | length) == 0
            then (if $pstate == "held"
                  then { rc: 3, why: "\($pausesay) — longer than the shift waits; rm .aif/state/pause to try anyway" }
                  else { rc: 0, why: "nothing left for the shift" } end)
            else null end) }
