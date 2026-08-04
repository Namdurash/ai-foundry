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
jq -n --arg s "$PLH" '{schema:1,gate:"plan-judge",subject:"plan.md",subject_sha256:$s,judge_agent:"aif-plan-judge",at:"t",guesses:[]}' > tasks/PROJ-1/verdict-plan.json
gate "plan judge" plan-judge PROJ-1 0
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
rm -f src/api/sneaky.py

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
step "done"
printf '  The pipeline ran end to end: %sTicket → Spec → Plan → Tests → Code%s,\n' "$bold" "$rst"
printf '  every boundary machine-checked, no model called.\n\n'
printf '  %sTo run it live%s (needs an authenticated claude in a real terminal):\n' "$bold" "$rst"
printf '    %saif run PROJ-1%s\n\n' "$dim" "$rst"
printf '  One command. It opens a session on the orchestrator, which interviews you,\n'
printf '  dispatches each station as a subagent, and runs these same gates between\n'
printf '  them — asking %saif _state%s what comes next rather than deciding itself.\n\n' "$dim" "$rst"

rm -rf "$DEMO"
