#!/usr/bin/env bash
#
# scripts/demo.sh — walk the whole pipeline OFFLINE, with no model calls.
#
# Every station's output is hand-written here instead of generated, so the gates
# run against known-good and known-bad artifacts and you can watch them accept
# and reject in sequence. The test suite is a state-sensitive stub, so verify-red
# and green run without pytest.
#
# This is the machine end to end without spending a token. The live pipeline is
# the same gates, with a subagent per station in place of the hand-written
# artifacts — see the end of this script.
#
# Usage:  bash scripts/demo.sh

set -uo pipefail

AIF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
AIF="$AIF_ROOT/bin/aif"

DEMO="$(mktemp -d "${TMPDIR:-/tmp}/aif-demo-XXXXXX")"
cd "$DEMO"

bold=$'\033[1m'; dim=$'\033[2m'; grn=$'\033[32m'; red=$'\033[31m'; rst=$'\033[0m'
step() { printf '\n%s▸ %s%s\n' "$bold" "$1" "$rst"; }
note() { printf '  %s%s%s\n' "$dim" "$1" "$rst"; }
gate() { # <label> <gate> <ticket> <expected-exit>
  local out rc=0
  out="$(/bin/bash ".aif/gates/$2.sh" "tasks/$3" 2>&1)" || rc=$?
  if [ "$rc" -eq "$4" ]; then
    printf '  %s✓%s %-12s exit %s  %s\n' "$grn" "$rst" "$2" "$rc" "$(printf '%s' "$out" | head -1)"
  else
    printf '  %s✗%s %-12s exit %s (wanted %s)  %s\n' "$red" "$rst" "$2" "$rc" "$4" "$(printf '%s' "$out" | head -1)"
  fi
}

printf '%sAI Foundry — offline pipeline demo%s\n' "$bold" "$rst"
note "sandbox: $DEMO"

# ---------------------------------------------------------------------------
step "1. a project on AI SDLC rails"
git init -q; git config user.email demo@aif; git config user.name "Demo"
printf '# Demo project\n' > CLAUDE.md
mkdir -p src/api tests
printf 'def create():\n    return 200\n' > src/api/users.py
git add -A; git commit -qm init >/dev/null

"$AIF" init anthropic >/dev/null
"$AIF" project init pytest >/dev/null
note "installed the claude set and detected the pytest runner"

# a state-sensitive stub test runner: green only once the implementation exists
cat > .aif/mkreport.sh <<'MK'
#!/bin/bash
mkdir -p .aif/tmp
if grep -q "409" src/api/users.py 2>/dev/null; then
  BODY='<testcase classname="tests.test_users" name="test_conflict" file="tests/test_users.py" line="3"/>'
else
  BODY='<testcase classname="tests.test_users" name="test_conflict" file="tests/test_users.py" line="3"><failure message="assert 200 == 409">AssertionError: assert 200 == 409</failure></testcase>'
fi
cat > .aif/tmp/report.xml <<X
<testsuites><testsuite tests="1">$BODY</testsuite></testsuites>
X
MK
chmod +x .aif/mkreport.sh
tmp="$(mktemp)"; jq '.test.command="bash .aif/mkreport.sh" | .test.report.path=".aif/tmp/report.xml"' .aif/project.json > "$tmp" && mv "$tmp" .aif/project.json

note "before anything costs money, aif run establishes that the gates can render"
note "a verdict at all — it RUNS the test command and checks a report comes out."
note "On a live ticket that missing piece surfaced at the LAST gate, ~\$6.61 in:"
if "$AIF" doctor --probe >/dev/null 2>&1; then
  printf '  %s✓%s %-12s toolchain usable\n' "$grn" "$rst" "doctor --probe"
else
  printf '  %s✗%s %-12s reported unusable\n' "$red" "$rst" "doctor --probe"
fi
note "and with the runner broken, it refuses rather than spending a ticket first:"
tmp="$(mktemp)"; jq '.test.command="definitely-not-a-real-command"' .aif/project.json > "$tmp"
cp .aif/project.json /tmp/aif-demo-proj.bak && mv "$tmp" .aif/project.json
if "$AIF" doctor --probe >/dev/null 2>&1; then
  printf '  %s✗%s %-12s said usable with a broken runner\n' "$red" "$rst" "doctor --probe"
else
  printf '  %s✓%s %-12s refuses on a broken runner\n' "$grn" "$rst" "doctor --probe"
fi
cp /tmp/aif-demo-proj.bak .aif/project.json && rm -f /tmp/aif-demo-proj.bak

# ---------------------------------------------------------------------------
step "2. start a ticket"
"$AIF" _ticket-init PROJ-1 >/dev/null
note "scaffolded tasks/PROJ-1/ (ticket.md + ledger.json)"
cat > tasks/PROJ-1/ticket.md <<'TICKET'
<!-- aif:meta
{ "schema": 1, "ticket": "PROJ-1", "lang": "en", "risk": "low" }
-->
# PROJ-1 — reject duplicate registration

Registering with an email that is already taken currently succeeds and creates a
second account. It should be refused, and the caller should be able to tell that
refusal apart from a validation error.
TICKET
note "and replaced the stub with a real ticket (live: the interview does this)"

state() { # <label> <expected next.step>
  local got; got="$("$AIF" _state PROJ-1 | jq -r '.next.step // .next.kind')"
  if [ "$got" = "$2" ]; then
    printf '  %s✓%s %-12s next: %s\n' "$grn" "$rst" "_state" "$got"
  else
    printf '  %s✗%s %-12s next: %s (wanted %s)\n' "$red" "$rst" "_state" "$got" "$2"
  fi
}
sgate() { # <station> <ticket> <expected-exit> — check a station the way the
  # orchestrator does: every gate it declares, recorded in the ledger.
  local out rc=0
  out="$("$AIF" _gate "$1" "$2" 2>&1)" || rc=$?
  if [ "$rc" -eq "$3" ]; then
    printf '  %s✓%s %-12s exit %s  %s\n' "$grn" "$rst" "_gate $1" "$rc" "$(printf '%s' "$out" | head -1)"
  else
    printf '  %s✗%s %-12s exit %s (wanted %s)  %s\n' "$red" "$rst" "_gate $1" "$rc" "$3" "$(printf '%s' "$out" | head -1)"
  fi
}

note "the state machine derives what is next by running the gates, so it cannot"
note "be stale — and the orchestrator obeys it rather than deciding for itself:"
state "fresh ticket" spec

# ---------------------------------------------------------------------------
step "3. SPECIFICATION boundary  —  spec-form → spec-judge → human"
cat > tasks/PROJ-1/spec.md <<'SPEC'
<!-- aif:meta
{ "schema": 1, "ticket": "PROJ-1", "lang": "en", "risk": "low",
  "surfaces": ["POST /api/users"],
  "acceptance": [
    { "id": "AC-001", "surface": "POST /api/users",
      "given": "a user with that email already exists",
      "when": "the same email is posted",
      "then": "responds with status", "expect": 409 } ],
  "assumptions": [ { "id": "AS-001", "text": "email uniqueness is case-insensitive" } ],
  "non_goals": ["password reset"] }
-->
# PROJ-1 — reject duplicate registration
SPEC
gate "spec form" spec-form PROJ-1 0

note "now the same gate on a BAD spec (vague expect, two assertions):"
mkdir -p tasks/BAD
cat > tasks/BAD/spec.md <<'SPEC'
<!-- aif:meta
{ "schema": 1, "ticket": "BAD-1", "lang": "en", "risk": "low", "surfaces": ["POST /x"],
  "acceptance": [ { "id": "AC-001", "surface": "POST /x", "given": "a", "when": "b",
    "then": "works properly and writes a log", "expect": "as expected" } ],
  "assumptions": [], "non_goals": [] }
-->
SPEC
gate "spec form" spec-form BAD 1

note "judge verdict (hand-written; live: the aif-spec-judge subagent):"
SH="$(shasum -a 256 tasks/PROJ-1/spec.md | cut -d' ' -f1)"
jq -n --arg s "$SH" '{schema:1,gate:"spec-judge",subject:"spec.md",subject_sha256:$s,judge_agent:"aif-spec-judge",at:"t",pass:true,findings:[]}' > tasks/PROJ-1/verdict-spec.json
gate "spec judge" spec-judge PROJ-1 0
state "spec judged, not approved" approve

note "human approval (hand-written; live: the orchestrator asks you in chat):"
jq -n --arg s "$SH" '{schema:1,subject:"spec.md",subject_sha256:$s,approver:"Demo",at:"t",channel:"chat",confirmation:"yes, that is what I meant",approved_assumptions:["AS-001"]}' > tasks/PROJ-1/approval.json
gate "spec approve" spec-approve PROJ-1 0

note "the backward transition, for free: append one line to spec.md and the"
note "approval below it lapses on its own — no 'go back' command needed:"
cp tasks/PROJ-1/spec.md /tmp/aif-demo-spec.bak
printf '\nan edit after approval\n' >> tasks/PROJ-1/spec.md
gate "spec approve" spec-approve PROJ-1 1
cp /tmp/aif-demo-spec.bak tasks/PROJ-1/spec.md; rm -f /tmp/aif-demo-spec.bak

# ---------------------------------------------------------------------------
step "4. PLAN boundary  —  plan-form → plan-judge (on the routine tier)"
SH="$(shasum -a 256 tasks/PROJ-1/spec.md | cut -d' ' -f1)"
cat > tasks/PROJ-1/plan.md <<PLAN
<!-- aif:meta
{ "schema": 1, "ticket": "PROJ-1", "spec_sha256": "$SH", "risk": "low",
  "files": { "create": [], "change": ["src/api/users.py"], "tests": ["tests/test_users.py"] },
  "decisions": [ { "id": "D-001", "statement": "Return 409 when the email already exists." } ],
  "ac_coverage": { "AC-001": ["src/api/users.py"] } }
-->
# PROJ-1 — plan
PLAN
gate "plan form" plan-form PROJ-1 0
PLH="$(shasum -a 256 tasks/PROJ-1/plan.md | cut -d' ' -f1)"
VERDICT='{schema:1,gate:"plan-judge",subject:"plan.md",subject_sha256:$s,judge_agent:"aif-plan-judge",at:"t",guesses:[],missing_files:[]}'
jq -n --arg s "$PLH" "$VERDICT" > tasks/PROJ-1/verdict-plan.json
gate "plan judge" plan-judge PROJ-1 0

note "the judge also reports files the implementation must edit that the manifest"
note "does not permit. scope would catch those too — but only after the code was"
note "written and paid for. Here it costs nothing:"
jq -n --arg s "$PLH" '{schema:1,gate:"plan-judge",subject:"plan.md",subject_sha256:$s,judge_agent:"aif-plan-judge",at:"t",guesses:[],missing_files:[{path:"src/api/router.py",why:"the new handler only takes effect once registered here"}]}' > tasks/PROJ-1/verdict-plan.json
gate "plan judge" plan-judge PROJ-1 1

note "and a verdict that omits the list is not the same claim as an empty one —"
note "a judge that did not report is a malfunction (exit 3), not a plan defect:"
jq -n --arg s "$PLH" '{schema:1,gate:"plan-judge",subject:"plan.md",subject_sha256:$s,judge_agent:"aif-plan-judge",at:"t",guesses:[]}' > tasks/PROJ-1/verdict-plan.json
gate "plan judge" plan-judge PROJ-1 3
jq -n --arg s "$PLH" "$VERDICT" > tasks/PROJ-1/verdict-plan.json
"$AIF" _commit plan PROJ-1 >/dev/null

# ---------------------------------------------------------------------------
step "5. TEST boundary  —  verify-red (fails for the right reason)"
cat > tests/test_users.py <<'PY'
def test_conflict():  # AC-001
    from src.api.users import create
    assert create() == 409
PY
sgate tests PROJ-1 0
note "the tests are RED now (create() returns 200), and red for a real assertion."
note "verify-red's pass is RECORDED, bound to tests.lock: it asserts the tests are"
note "red, which stops being true the moment implementation starts, so the record"
note "is the verdict from here on — re-running it later would report a false alarm."
"$AIF" _commit tests PROJ-1 >/dev/null

# ---------------------------------------------------------------------------
step "6. CODE boundary  —  green (+ revert-recheck) → scope"
note "implement: make the test pass, touching only the plan's files"
printf 'def create():\n    return 409\n' > src/api/users.py
sgate implement PROJ-1 0
"$AIF" _commit implement PROJ-1 >/dev/null
note "green re-ran with the code reverted and confirmed the test goes red again"
note "every gate now passes against current bytes, so the ticket is done:"
state "all gates pass" done

note "now break scope — touch a file the plan never named:"
printf 'x\n' > src/api/sneaky.py
gate "scope" scope PROJ-1 1

note "the plan could genuinely not have foreseen it — an import pulls in a"
note "neighbour, a handler needs registering. That is a gap, not a violation, and"
note "there is a way through it that is capped and leaves a reason behind:"
"$AIF" _amend-plan PROJ-1 src/api/sneaky.py "the handler only takes effect once registered here" 2>&1 | head -2
gate "scope" scope PROJ-1 0
note "scope names the amendment on the PASS path — a widened manifest that only"
note "shows up when someone goes looking is the same as no manifest at all:"
/bin/bash .aif/gates/scope.sh tasks/PROJ-1 2>&1 | tail -2 | sed 's/^/  /'

note "what it refuses: a test file, and the pipeline's own record."
amend() { # <label> <path> — must be refused
  if "$AIF" _amend-plan PROJ-1 "$2" "because" >/dev/null 2>&1; then
    printf '  %s✗%s %-28s was ALLOWED\n' "$red" "$rst" "$1"
  else
    printf '  %s✓%s %-28s refused\n' "$grn" "$rst" "$1"
  fi
}
amend "amend for a test file" "tests/test_users.py"
amend "amend for the plan itself" "tasks/PROJ-1/plan.md"
amend "amend for a gate" ".aif/gates/scope.sh"
amend "amend for a file not there" "src/api/imaginary.py"

note "and it is capped. Past the cap the plan is not being widened, it is being"
note "replaced — which is a planning decision, not an implementation one:"
for n in 2 3 4; do printf 'x\n' > "src/api/extra$n.py"; done
"$AIF" _amend-plan PROJ-1 src/api/extra2.py "b" >/dev/null 2>&1
"$AIF" _amend-plan PROJ-1 src/api/extra3.py "c" >/dev/null 2>&1
amend "the fourth amendment (cap 3)" "src/api/extra4.py"

git checkout -q -- tasks/PROJ-1/ 2>/dev/null || true
rm -f tasks/PROJ-1/plan-amendments.json src/api/sneaky.py src/api/extra*.py

note "now the denylist, which is a different defence. Above, sneaky.py was caught"
note "for not being in the plan — so an implementation that simply ADDS itself to"
note "the plan would walk straight through. Here it does exactly that: it lists"
note "the plan and the ledger as files it may change, then edits the ledger. Every"
note "changed file is now permitted, and only the denylist is left standing:"
cp tasks/PROJ-1/plan.md /tmp/aif-demo-plan.bak
perl -pi -e 's{"change": \["src/api/users\.py"\]}{"change": ["src/api/users.py", "tasks/PROJ-1/plan.md", "tasks/PROJ-1/ledger.json"]}' tasks/PROJ-1/plan.md
printf '{"tampered":true}\n' > tasks/PROJ-1/ledger.json
gate "scope" scope PROJ-1 1
cp /tmp/aif-demo-plan.bak tasks/PROJ-1/plan.md
git checkout -q -- tasks/PROJ-1/ledger.json

# ---------------------------------------------------------------------------
step "7. ACCOUNTING  —  what a station cost, from its own transcript"

check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then
    printf '  %s✓%s %-28s %s\n' "$grn" "$rst" "$1" "$2"
  else
    printf '  %s✗%s %-28s %s (wanted %s)\n' "$red" "$rst" "$1" "$2" "$3"
  fi
}

# A subagent transcript with both measured traps in it: one message repeated
# three times under the same id (usage repeats per content block — a real file
# had 36 rows for 14 requests), and a "<synthetic>" entry, which is not billed.
TR="$DEMO/agent-demo.jsonl"
{
  for _ in 1 2 3; do
    printf '{"type":"assistant","message":{"id":"m1","model":"demo-model","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50}}}\n'
  done
  printf '{"type":"assistant","message":{"id":"m2","model":"demo-model","usage":{"input_tokens":5,"output_tokens":40,"cache_read_input_tokens":2000,"cache_creation_input_tokens":0}}}\n'
  printf '{"type":"assistant","message":{"id":"ms","model":"<synthetic>","usage":{"input_tokens":9999,"output_tokens":9999,"cache_read_input_tokens":9999,"cache_creation_input_tokens":9999}}}\n'
} > "$TR"

meter() { # <agent_type> <transcript>
  jq -n --arg a "$1" --arg t "$2" \
    '{agent_type:$a, agent_id:"demo", agent_transcript_path:$t, last_assistant_message:"done"}' |
    "$AIF" _meter 2>/dev/null
}

note "the transcript repeats usage per content block and carries a <synthetic>"
note "row; counted naively that is 3x the output tokens plus 9999 unbilled ones:"
meter aif-plan "$TR"
last_plan() { jq -r --arg k "$1" '[.entries[]|select(.station=="plan")]|last|.[$k]//"null"' tasks/PROJ-1/ledger.json; }
check "deduped output tokens" "$(jq -r '[.entries[]|select(.station=="plan")]|last|.usage.output_tokens' tasks/PROJ-1/ledger.json)" "140"
check "turns, not content blocks" "$(last_plan num_turns)" "2"
check "unpriced model → null cost" "$(last_plan cost_usd)" "null"

note "now with a price table (1/5/0.1/1.25 per MTok): 15 + 700 + 300 + 62.5 = \$0.0010775"
jq '.models={"demo-model":{"input":1,"output":5,"cache_read":0.1,"cache_write":1.25}}' \
  .aif/prices.json > .aif/p.tmp && mv .aif/p.tmp .aif/prices.json
meter aif-plan "$TR"
check "priced from tokens" "$(last_plan cost_usd)" "0.0010775"

note "a station that left no transcript is RECORDED as unmetered, never skipped —"
note "a gap that announces itself is recoverable; a silent one flatters the total:"
meter aif-tests "/nonexistent.jsonl"
check "missing transcript" "$(jq -r '[.entries[]|select(.station=="tests" and .result=="unmetered")]|length' tasks/PROJ-1/ledger.json)" "1"

note "a subagent that is not a station is not a pipeline cost:"
BEFORE=$(jq '.entries|length' tasks/PROJ-1/ledger.json)
meter general-purpose "$TR"
check "unrelated subagent ignored" "$(jq '.entries|length' tasks/PROJ-1/ledger.json)" "$BEFORE"

note "subagents finish whenever they finish, so the append is locked. Eight at"
note "once, and the hash chain still has to verify end to end:"
BEFORE=$(jq '.entries|length' tasks/PROJ-1/ledger.json)
for _ in 1 2 3 4 5 6 7 8; do meter aif-spec "$TR" & done
wait
check "no row lost to a race" "$(jq '.entries|length' tasks/PROJ-1/ledger.json)" "$((BEFORE + 8))"

N=$(jq '.entries|length' tasks/PROJ-1/ledger.json); BROKEN=0; i=1
while [ "$i" -lt "$N" ]; do
  want=$(jq -r ".entries[$i].prev" tasks/PROJ-1/ledger.json)
  got=$(jq -S -c ".entries[$((i-1))]" tasks/PROJ-1/ledger.json | tr -d '\n' | shasum -a 256 | cut -d' ' -f1)
  [ "$want" = "$got" ] || BROKEN=$((BROKEN + 1))
  i=$((i + 1))
done
check "hash chain unbroken" "$BROKEN" "0"
git checkout -q -- tasks/PROJ-1/ledger.json 2>/dev/null || true

# ---------------------------------------------------------------------------
step "done"
printf '  The pipeline ran end to end: %sTicket → Spec → Plan → Tests → Code%s,\n' "$bold" "$rst"
printf '  every boundary machine-checked, no model called.\n\n'
printf '  %sTo run it live%s (needs an authenticated claude in a real terminal):\n' "$bold" "$rst"
printf '    %saif run PROJ-1%s\n\n' "$dim" "$rst"
printf '  One command. It opens a session on the orchestrator, which interviews you,\n'
printf '  dispatches each station as a subagent, and runs these same gates between\n'
printf '  them — asking %saif _state%s what comes next rather than deciding itself.\n\n' "$dim" "$rst"

rm -rf "$DEMO"
