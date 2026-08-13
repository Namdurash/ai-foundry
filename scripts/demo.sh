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

check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then
    printf '  %s✓%s %-28s %s\n' "$grn" "$rst" "$1" "$2"
  else
    printf '  %s✗%s %-28s %s (wanted %s)\n' "$red" "$rst" "$1" "$2" "$3"
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
"$AIF" project init pytest --no-checks >/dev/null
note "installed the claude set and detected the pytest runner"

# Upgrading a project is a re-init, and a re-init takes a different path through
# every file aif shares with the user: the marked block is rewritten in place
# rather than appended. Nothing exercised that path, so a multi-line .gitignore
# block broke it and only showed up on the second install a user ever ran —
# after the set had already been copied over and before the manifest recording
# it was written.
reinit_rc=0; "$AIF" init anthropic >/dev/null 2>&1 || reinit_rc=$?
check "re-init exits clean" "$reinit_rc" "0"
check "manifest survives it" \
  "$(jq -r '.set_version' .aif/manifest.json 2>/dev/null)" \
  "$(awk -F= '/^SET_VERSION=/ { print $2 }' "$AIF_ROOT/sets/claude/set.meta")"
check "the ignore block is intact" \
  "$(grep -c '^\.aif/\(profile\.local\|tmp/\|state/\)$' .gitignore)" "3"
check "no scratch file left behind" "$(ls -a | grep -c '^\.aif-tmp-')" "0"

# --force is how a project takes an edited file back, and it promises a backup of
# what it overwrites. The backup was keyed on the BASENAME, so the set's three
# SKILL.md files (one per skill directory) all wrote the same
# .aif/backups/SKILL.md.orig — --force destroyed two of the three copies it said
# it was keeping, and nothing exercised --force at all.
note "--force takes back files the user edited, and keeps a backup of each. Every"
note "file the set ships gets one, by its own path — two skills both shipping a"
note "SKILL.md must not land on the same backup:"
while IFS= read -r f; do printf '\n# edited by hand\n' >>"$f"; done < <(
  jq -r '.files[].path' .aif/manifest.json)
# Counted from what --force says it took, not from the manifest: the manifest
# also tracks generated files (.aif/profile.local) that the set never ships.
taken="$("$AIF" init anthropic --force 2>&1 | awk '$1 == "update" || $1 == "create" { print $2 }')"
n_taken="$(printf '%s\n' "$taken" | grep -c .)"
check "one backup per file taken" \
  "$(find .aif/backups -type f -name '*.orig' | wc -l | tr -d ' ')" "$n_taken"
check "same basename, separate backups" \
  "$(find .aif/backups -type f -name 'SKILL.md.orig' | wc -l | tr -d ' ')" \
  "$(find "$AIF_ROOT/sets/claude/skills" -type f -name 'SKILL.md' | wc -l | tr -d ' ')"
check "every backup is the user's copy" \
  "$(grep -rl 'edited by hand' .aif/backups | wc -l | tr -d ' ')" "$n_taken"
check "and the set's copy is back" "$(grep -c 'edited by hand' .aif/foundry.md)" "0"
rm -rf .aif/backups

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
tmp="$(mktemp)"; jq '.test.command="bash .aif/mkreport.sh" | .test.report.path=".aif/tmp/report.xml"
  | .checks=[{name:"typecheck",command:"exit 0",phase:["green"],required:true}]' \
  .aif/project.json > "$tmp" && mv "$tmp" .aif/project.json
note "and project.json now carries a second thing that must hold besides the tests:"
note "a check, bound to the green phase. green runs it; the ledger records it by name."

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
  "verification_gaps": [
    { "id": "VG-001", "text": "two simultaneous posts of the same email are not exercised by this suite" } ],
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
  "assumptions": [], "verification_gaps": [], "non_goals": [] }
-->
SPEC
gate "spec form" spec-form BAD 1

note "judge verdict (hand-written; live: the aif-spec-judge subagent):"
SH="$(shasum -a 256 tasks/PROJ-1/spec.md | cut -d' ' -f1)"
jq -n --arg s "$SH" '{schema:1,gate:"spec-judge",subject:"spec.md",subject_sha256:$s,judge_agent:"aif-spec-judge",at:"t",pass:true,findings:[]}' > tasks/PROJ-1/verdict-spec.json
gate "spec judge" spec-judge PROJ-1 0
state "spec judged, not approved" approve

note "human approval (hand-written; live: the orchestrator asks you in chat):"
jq -n --arg s "$SH" '{schema:1,subject:"spec.md",subject_sha256:$s,approver:"Demo",at:"t",channel:"chat",confirmation:"yes, that is what I meant",approved_assumptions:["AS-001"],acknowledged_gaps:["VG-001"],gaps_confirmation:"understood, we will try the race by hand"}' > tasks/PROJ-1/approval.json
gate "spec approve" spec-approve PROJ-1 0

note "the backward transition, for free: append one line to spec.md and the"
note "approval below it lapses on its own — no 'go back' command needed:"
cp tasks/PROJ-1/spec.md /tmp/aif-demo-spec.bak
printf '\nan edit after approval\n' >> tasks/PROJ-1/spec.md
gate "spec approve" spec-approve PROJ-1 1
cp /tmp/aif-demo-spec.bak tasks/PROJ-1/spec.md; rm -f /tmp/aif-demo-spec.bak

# ---------------------------------------------------------------------------
step "3b. the blind spot that must not dissolve into the approval"
note "an assumption says how the system BEHAVES. A sentence saying the device"
note "path is not exercised by the suite says something else: what this run will"
note "NOT establish. Filed together, the second disappears into the first — on a"
note "live ticket a human approved both with one keystroke, and nothing referred"
note "to the blind spot again:"
"$AIF" _ticket-init GAP-1 >/dev/null
cat > tasks/GAP-1/spec.md <<'SPEC'
<!-- aif:meta
{ "schema": 1, "ticket": "GAP-1", "lang": "en", "risk": "high",
  "surfaces": ["secret storage"],
  "acceptance": [
    { "id": "AC-001", "surface": "secret storage",
      "given": "a stored secret", "when": "it is read back",
      "then": "returns the value", "expect": "s3cret" } ],
  "assumptions": [ { "id": "AS-001", "text": "one process reads the store at a time" } ],
  "verification_gaps": [
    { "id": "VG-001", "text": "the on-device encrypted path is not exercised by this suite" } ],
  "non_goals": [] }
SPEC
gate "spec form" spec-form GAP-1 0
GH="$(shasum -a 256 tasks/GAP-1/spec.md | cut -d' ' -f1)"
note "and on a risk: high ticket, findings: [] is the shape of a thorough pass"
note "and also the shape of a judge that read nothing. From the artifact alone"
note "those are the same document, so the judge has to name what it examined:"
jq -n --arg s "$GH" '{schema:1,gate:"spec-judge",subject:"spec.md",subject_sha256:$s,judge_agent:"aif-spec-judge",at:"t",pass:true,findings:[]}' > tasks/GAP-1/verdict-spec.json
gate "spec judge" spec-judge GAP-1 3
jq -n --arg s "$GH" '{schema:1,gate:"spec-judge",subject:"spec.md",subject_sha256:$s,judge_agent:"aif-spec-judge",at:"t",pass:true,findings:[],checked:["AC-001 against the ticket text","the assumption list for silent decisions"]}' > tasks/GAP-1/verdict-spec.json
gate "spec judge" spec-judge GAP-1 0

note "an approval that accepts the assumptions and says nothing about the gap:"
jq -n --arg s "$GH" '{schema:1,subject:"spec.md",subject_sha256:$s,approver:"Demo",at:"t",channel:"chat",confirmation:"fine",approved_assumptions:["AS-001"]}' > tasks/GAP-1/approval.json
gate "spec approve" spec-approve GAP-1 1
note "and aif refuses to record one — accepting a blind spot is its own decision:"
if "$AIF" _approve GAP-1 --confirmation "fine" >/dev/null 2>&1; then
  printf '  %s✗%s %-28s recorded it anyway
' "$red" "$rst" "approve without the gap"
else
  printf '  %s✓%s %-28s refused
' "$grn" "$rst" "approve without the gap"
fi
"$AIF" _approve GAP-1 --confirmation "fine" \
  --gaps-confirmation "yes — I accept nothing here tests the real device" >/dev/null
gate "spec approve" spec-approve GAP-1 0
check "the gap is on the record"   "$(jq -r '.acknowledged_gaps | join(",")' tasks/GAP-1/approval.json)" "VG-001"

# ---------------------------------------------------------------------------
step "4. PLAN boundary  —  plan-form → plan-judge (on the routine tier)"
SH="$(shasum -a 256 tasks/PROJ-1/spec.md | cut -d' ' -f1)"
cat > tasks/PROJ-1/plan.md <<PLAN
<!-- aif:meta
{ "schema": 1, "ticket": "PROJ-1", "spec_sha256": "$SH", "risk": "low",
  "files": { "create": [], "change": ["src/api/users.py"], "tests": ["tests/test_users.py"] },
  "decisions": [ { "id": "D-001", "statement": "Return 409 when the email already exists." } ],
  "ac_coverage": { "AC-001": ["src/api/users.py"] },
  "surface_map": { "POST /api/users": ["src/api/users.py"] },
  "uncovered": [],
  "external": [] }
-->
# PROJ-1 — plan
PLAN
gate "plan form" plan-form PROJ-1 0
note "three coverage questions of one shape are asked of a plan, about three"
note "kinds of thing. First: a file the plan orders into existence that no"
note "criterion points at is a blind spot by construction. On a live ticket that"
note "file was the module barrel — it threw on import, and no test noticed:"
cp tasks/PROJ-1/plan.md /tmp/aif-demo-plan1.bak
plan_edit() { # <jq filter> — rewrite the plan's meta block in place
  local meta rest
  meta="$(sed -n '/^<!-- aif:meta$/,/^-->$/p' tasks/PROJ-1/plan.md | sed '1d;$d' | jq -c "$1")"
  rest="$(awk 'body { print } /^-->$/ { body = 1 }' tasks/PROJ-1/plan.md)"
  { printf '<!-- aif:meta\n%s\n-->\n' "$meta"; printf '%s\n' "$rest"; } > tasks/PROJ-1/plan.md
}
plan_edit '.files.create=["src/api/index.py"]'
gate "plan form" plan-form PROJ-1 1
note "the way through is not to invent a criterion — it is to say so, in a list"
note "the human is shown at the gate:"
plan_edit '.uncovered=["src/api/index.py"]'
gate "plan form" plan-form PROJ-1 0
/bin/bash .aif/gates/plan-form.sh tasks/PROJ-1 2>&1 | tail -2 | sed 's/^/  /'
cp /tmp/aif-demo-plan1.bak tasks/PROJ-1/plan.md

note "second: the external surface. Every 'because' a planning model writes"
note "points BACKWARDS into the spec — which proves conformance to the spec and"
note "is structurally incapable of proving conformance to reality. So the plan"
note "enumerates what it will touch outside the repo, and each entry names what"
note "validates it. A name that matches no check is caught against project.json:"
plan_edit '.external=[{name:"the mail provider SDK",check:"no-such-check"}]'
gate "plan form" plan-form PROJ-1 1
note "and an entry nothing validates is not rejected — it is SHOWN. Some things"
note "genuinely cannot be exercised in CI; what is not acceptable is not knowing:"
plan_edit '.external=[{name:"the mail provider SDK"}]'
gate "plan form" plan-form PROJ-1 0
/bin/bash .aif/gates/plan-form.sh tasks/PROJ-1 2>&1 | tail -3 | sed 's/^/  /'
cp /tmp/aif-demo-plan1.bak tasks/PROJ-1/plan.md

note "third: one surface, one file set. Four criteria on one live ticket declared"
note "the same surface and were mapped to three different file sets; the narrowest"
note "pinned a standalone function instead of the startup path it was written for."
note "That is a drift signal, not a proof — so it routes to the judge:"
printf 'def send():\n    return None\n' > src/api/mailer.py
plan_edit '.files.change=["src/api/users.py","src/api/mailer.py"]
  | .surface_map={"POST /api/users":["src/api/users.py","src/api/mailer.py"]}'
gate "plan form" plan-form PROJ-1 0
/bin/bash .aif/gates/plan-form.sh tasks/PROJ-1 2>&1 | tail -2 | sed 's/^/  /'
DPLH="$(shasum -a 256 tasks/PROJ-1/plan.md | cut -d' ' -f1)"
note "a verdict that ignores the flag is not a verdict — the judge has to decide:"
jq -n --arg s "$DPLH" '{schema:1,gate:"plan-judge",subject:"plan.md",subject_sha256:$s,judge_agent:"aif-plan-judge",at:"t",guesses:[],missing_files:[]}' > tasks/PROJ-1/verdict-plan.json
gate "plan judge" plan-judge PROJ-1 3
note "it can say the narrowing is intended, and the plan proceeds:"
jq -n --arg s "$DPLH" '{schema:1,gate:"plan-judge",subject:"plan.md",subject_sha256:$s,judge_agent:"aif-plan-judge",at:"t",guesses:[],missing_files:[],surface_adjudications:[{ac:"AC-001",verdict:"intended",why:"the mailer is not on the conflict path"}]}' > tasks/PROJ-1/verdict-plan.json
gate "plan judge" plan-judge PROJ-1 0
note "or that it is drift — and then it is the PLAN that is wrong, not the flag:"
jq -n --arg s "$DPLH" '{schema:1,gate:"plan-judge",subject:"plan.md",subject_sha256:$s,judge_agent:"aif-plan-judge",at:"t",guesses:[],missing_files:[],surface_adjudications:[{ac:"AC-001",verdict:"drift",why:"the criterion is about the whole POST path, not one file"}]}' > tasks/PROJ-1/verdict-plan.json
gate "plan judge" plan-judge PROJ-1 1
cp /tmp/aif-demo-plan1.bak tasks/PROJ-1/plan.md; rm -f /tmp/aif-demo-plan1.bak src/api/mailer.py

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
note "test.roots is the SMUGGLING NET over the shared test tree — the tree green"
note "re-hashes so logic cannot hide in a fixture no plan lists. It is not the"
note "source of truth for one ticket's tests. Point it somewhere else entirely and"
note "the ticket's own oracle is STILL frozen, because the plan declares it:"
cp .aif/project.json /tmp/aif-demo-roots.bak
tmp="$(mktemp)"; jq '.test.roots=["nowhere"]' .aif/project.json > "$tmp" && mv "$tmp" .aif/project.json
gate "verify-red" verify-red PROJ-1 0
check "the plan's tests are frozen" \
  "$(jq -r '.tests | has("tests/test_users.py")' tasks/PROJ-1/tests.lock.json)" "true"
note "that is the freeze failing silently on a live ticket: roots pointed at one"
note "tree, the tests lived beside their sources, and the lock held neither — so"
note "the implement station was free to edit the oracle it was judged against."
cp /tmp/aif-demo-roots.bak .aif/project.json && rm -f /tmp/aif-demo-roots.bak

sgate tests PROJ-1 0
note "the tests are RED now (create() returns 200), and red for a real assertion."
note "verify-red's pass is RECORDED, bound to tests.lock.json: it asserts the tests are"
note "red, which stops being true the moment implementation starts, so the record"
note "is the verdict from here on — re-running it later would report a false alarm."
"$AIF" _commit tests PROJ-1 >/dev/null

# ---------------------------------------------------------------------------
step "6. CODE boundary  —  green (+ revert-recheck) → scope"
note "implement: make the test pass, touching only the plan's files"
printf 'def create():\n    return 409\n' > src/api/users.py

note "a green suite is not a Definition of Done. Whatever else has to hold — a"
note "compiler, a linter, a dependency-integrity check — is a check in project.json,"
note "and green fails the station when a required one does. Before this, green read"
note "one thing (.test.command), so a project could not even express the rest:"
cp .aif/project.json /tmp/aif-demo-checks.bak
tmp="$(mktemp)"; jq '.checks[0].command="exit 2"' .aif/project.json > "$tmp" && mv "$tmp" .aif/project.json
gate "green" green PROJ-1 1
cp /tmp/aif-demo-checks.bak .aif/project.json && rm -f /tmp/aif-demo-checks.bak
note "phase binding is not decoration. The tests station writes FAILING tests"
note "before any implementation exists, so a compiler bound to THAT moment would"
note "fail correctly and reject the red phase for being red by design — which is"
note "why a check names its phase, and why these default to green:"
sgate implement PROJ-1 0
check "the check is attributable" \
  "$(jq -r '[.entries[]|select(.event=="check")]|last|.check + ":" + .result' tasks/PROJ-1/ledger.json)" \
  "typecheck:pass"
"$AIF" _commit implement PROJ-1 >/dev/null
note "green re-ran with the code reverted and confirmed the test goes red again"
note "every gate now passes against current bytes, so the ticket is done:"
state "all gates pass" done

note "and a lock that does not hold this ticket's oracle is not a weaker lock, it"
note "is a lock over the wrong files. green refuses to render a verdict on one:"
cp tasks/PROJ-1/tests.lock.json /tmp/aif-demo-lock.bak
tmp="$(mktemp)"; jq 'del(.tests["tests/test_users.py"])' tasks/PROJ-1/tests.lock.json > "$tmp" \
  && mv "$tmp" tasks/PROJ-1/tests.lock.json
gate "green" green PROJ-1 3
cp /tmp/aif-demo-lock.bak tasks/PROJ-1/tests.lock.json && rm -f /tmp/aif-demo-lock.bak

note "and at close, what this run did NOT establish comes back as a checklist."
note "The blind spot was acknowledged once at approval; a pipeline that never"
note "mentions it again has the same blind spot as one that never named it:"
check "the gap is re-emitted at close" \
  "$("$AIF" _state PROJ-1 | jq -r '.next.checklist[] | .source + ":" + .id')" "spec:VG-001"

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
