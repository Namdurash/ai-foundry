#!/usr/bin/env bash
#
# scripts/check-cycle.sh — the SECOND-ROUND eval: rework → re-plan → re-tests →
# done, on a half-implemented ticket. Deterministic, offline, free.
#
# Six of the ten defects of the 0.4.1 set lived on exactly this route, and no
# eval walked it: every fixture used to start clean, so a gate that was only
# correct on a first round looked correct on every round. This script drives
# one ticket through the full gated cycle TWICE — the second time over the
# wreckage of the first — with every station's output hand-written, the same
# trade the offline demo makes: the machine end to end, no model, no tokens.
#
# What the route proves, by defect:
#   1  a station cost row staged by the meter is folded into the ledger by the
#      gate, and scope accepts a retry whose diff carries the ledger
#   2  the no-progress guard fires on a true stall and releases on a rewrite
#   3  a recorded verify-red pass lapses when the plan under it is replaced
#   5  a test green at freeze is recorded, kept out of covering, and
#      re-surfaced on the closing checklist
#   6  _state hands the dispatch bindings the stations must copy
#   8  a rework — an edit to the ticket's criteria — lapses the plan on its
#      own, through the plan's ticket_sha256, and the ready gate re-judges the
#      edited ticket on its current bytes
#   10 a finished first round still reaches done, and the second round's plan
#      names the file the first round created — as files.change, honestly
#
# Run by `make check`. Requires git, jq and python3 (verify-red's per-test
# mode); without python3 it skips rather than half-runs.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
AIF="$ROOT/bin/aif"

for tool in git jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'check-cycle: %s not found — cannot run\n' "$tool"
    exit 1
  }
done
if ! command -v python3 >/dev/null 2>&1; then
  printf 'check-cycle: skipped — python3 is required for per-test verify-red\n'
  exit 0
fi

fails=0
ok() { printf '  ✓ %s\n' "$1"; }
bad() {
  printf '  ✗ %s\n' "$1"
  fails=$((fails + 1))
}
eq() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2', wanted '$3'"; fi
}
sgate() { # <station> <expected-exit> <label>
  local rc=0 out
  out="$("$AIF" _gate "$1" AIF-1 2>&1)" || rc=$?
  if [ "$rc" -eq "$2" ]; then
    ok "$3"
  else
    bad "$3: _gate $1 exit $rc, wanted $2 — $(printf '%s' "$out" | head -1)"
  fi
}
nextof() { "$AIF" _state AIF-1 | jq -r '.next.step // .next.kind'; }
nextkind() { "$AIF" _state AIF-1 | jq -r '.next.kind'; }
binding() { "$AIF" _state AIF-1 | jq -r --arg k "$1" '.next.bindings[$k] // ""'; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/aif-cycle-XXXXXX")"
cd "$SANDBOX" || exit 1

printf '\nsecond-round cycle (sandbox: %s)\n' "$SANDBOX"

# --- a project on the rails, with a state-sensitive stub suite --------------
git init -q
git config user.email cycle@aif
git config user.name "Cycle"
mkdir -p src tests
printf 'def users():\n    return []\n' > src/app.py
git add -A && git commit -qm init >/dev/null

"$AIF" init anthropic >/dev/null 2>&1 || {
  printf 'check-cycle: aif init failed — cannot continue\n'
  exit 1
}
"$AIF" project init pytest --no-checks >/dev/null 2>&1

# The suite is a stub that reads the tree: a testcase per EXISTING declared
# test file, red or green depending on whether its implementation marker is in
# place. Deterministic, and exactly as state-sensitive as a real suite.
cat > .aif/suite.sh <<'SUITE'
#!/bin/bash
mkdir -p .aif/tmp
row() { # <id> <file> <green?>
  if [ "$3" = 1 ]; then
    printf '<testcase name="%s" file="%s"/>' "$1" "$2"
  else
    printf '<testcase name="%s" file="%s"><failure message="assert marker missing">AssertionError: assert marker missing</failure></testcase>' "$1" "$2"
  fi
}
body=""
if [ -f tests/t1.py ]; then
  g=0; grep -q impl1 src/app.py 2>/dev/null && g=1
  body="$body$(row t1 tests/t1.py "$g")"
fi
if [ -f tests/t2.py ]; then
  g=0; grep -q impl2 src/export.py 2>/dev/null && g=1
  body="$body$(row t2 tests/t2.py "$g")"
fi
if [ -f tests/t3.py ]; then
  g=0; grep -q impl3 src/app.py 2>/dev/null && g=1
  body="$body$(row t3 tests/t3.py "$g")"
fi
printf '<testsuites><testsuite>%s</testsuite></testsuites>' "$body" > .aif/tmp/report.xml
SUITE
chmod +x .aif/suite.sh
tmp="$(mktemp)"
jq '.test.command = "bash .aif/suite.sh"
    | .test.roots = ["tests"]
    | .test.report.path = ".aif/tmp/report.xml"' .aif/project.json > "$tmp" && mv "$tmp" .aif/project.json

# =============================== ROUND ONE ==================================
printf '\nround one — a clean run to done\n'

"$AIF" _ticket-init AIF-1 >/dev/null
eq "state: the scaffold stub is not a ticket" "$(nextof)" "ticket"

# write_ticket <extra-criterion-json-or-empty> — the analyst's output: criteria
# in the ticket, one question decided by default, one recorded gap.
write_ticket() {
  cat > tasks/AIF-1/ticket.md <<TICKET
<!-- aif:meta
{ "schema": 2, "ticket": "AIF-1", "lang": "en", "risk": "low",
  "surfaces": ["export"],
  "acceptance": [
    { "id": "AC-001", "surface": "export",
      "given": "users exist", "when": "the export runs",
      "then": "writes the marker", "expect": "impl1" },
    { "id": "AC-002", "surface": "export",
      "given": "the module is imported", "when": "the export runs",
      "then": "writes the module marker", "expect": "impl2" }${1:-} ],
  "open": [],
  "decided": [
    { "question": "may the export be deferred to a queue?", "answer": "no — synchronous", "by": "default" } ],
  "verification_gaps": [
    { "id": "VG-001", "text": "nothing here runs against a real user list", "leaves": ["AC-001"] } ],
  "non_goals": [] }
-->
# AIF-1 — one-command user export

Support needs a one-command export: write the current user list through a
new export module, so it can be pulled without touching the database.
TICKET
}
write_ticket
eq "state: a ready ticket routes to plan" "$(nextof)" "plan"

# The Definition of Ready is one gate with two callers. Here, the analyst's.
rc=0; out="$("$AIF" _ready AIF-1 2>&1)" || rc=$?
eq "_ready passes the analyst's ticket" "$rc" "0"
eq "and says what was decided by default" "$(printf '%s' "$out" | grep -c 'DECIDED BY DEFAULT')" "1"

# The dispatch contract (defect 6/8): the hash the plan must copy arrives in
# next.bindings — the harness consumes it exactly as the worker would.
TH="$(binding ticket_sha256)"
eq "bindings carry ticket_sha256 for plan" "$TH" "$(sha tasks/AIF-1/ticket.md)"

write_plan() { # <ticket-hash> <create-json> <change-json> <tests-json> <ac_coverage-json> <title>
  cat > tasks/AIF-1/plan.md <<PLAN
<!-- aif:meta
{ "schema": 2, "ticket": "AIF-1", "ticket_sha256": "$1", "risk": "low",
  "files": { "create": $2, "change": $3, "tests": $4 },
  "decisions": [
    { "id": "D-001", "statement": "Write the export through a dedicated module.",
      "because": "the ticket asks for a module the app does not have",
      "serves": ["AC-002"] } ],
  "ac_coverage": $5,
  "uncovered": [],
  "surface_map": { "export": ["src/app.py", "src/export.py"] },
  "external": [] }
-->
# AIF-1 — $6
PLAN
}
write_plan "$TH" '["src/export.py"]' '["src/app.py"]' '["tests/t1.py", "tests/t2.py"]' \
  '{ "AC-001": ["src/app.py", "src/export.py"], "AC-002": ["src/app.py", "src/export.py"] }' "plan, round one"
sgate plan 0 "plan-form admits the round-one plan (files.create not there yet)"
eq "state: plan recorded routes to plan-judge" "$(nextof)" "plan-judge"
PJ="$(binding subject_sha256)"
eq "bindings carry the judged plan's hash" "$PJ" "$(sha tasks/AIF-1/plan.md)"
jq -n --arg s "$PJ" '{schema:1,gate:"plan-judge",subject:"plan.md",subject_sha256:$s,
  judge_agent:"aif-plan-judge",at:"t",guesses:[],missing_files:[]}' \
  > tasks/AIF-1/verdict-plan.json
sgate plan-judge 0 "plan-judge verdict admitted"
"$AIF" _commit plan AIF-1 >/dev/null

eq "state: plan judged routes to tests" "$(nextof)" "tests"
printf '# AC-001 asserts impl1\n' > tests/t1.py
printf '# AC-002 asserts impl2\n' > tests/t2.py
sgate tests 0 "verify-red freezes two red tests"
eq "round-one covering is both tests" \
  "$(jq -c '.covering | sort' tasks/AIF-1/tests.lock.json)" '["t1","t2"]'
eq "round-one green_at_freeze is empty" \
  "$(jq -c '.green_at_freeze' tasks/AIF-1/tests.lock.json)" '[]'
"$AIF" _commit tests AIF-1 >/dev/null

eq "state: frozen tests route to implement" "$(nextof)" "implement"

# The metering hook (defect 1): stage a cost row exactly as SubagentStop would,
# from a fabricated transcript. It must NOT touch the ledger yet. The
# transcript lives outside the repo — a real one does too, and an untracked
# file inside would rightly be scope's business.
TR="$(mktemp "${TMPDIR:-/tmp}/aif-cycle-tr-XXXXXX")"
printf '{"message":{"id":"m1","model":"cycle-model","usage":{"input_tokens":10,"output_tokens":25,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$TR"
jq -n --arg t "$TR" '{agent_type:"aif-implement", agent_id:"cyc-impl-1",
  agent_transcript_path:$t, last_assistant_message:"done"}' | "$AIF" _meter >/dev/null 2>&1
eq "meter stages, does not write the ledger" \
  "$(jq '[.entries[] | select(.station == "implement")] | length' tasks/AIF-1/ledger.json)" "0"
if [ -f .aif/tmp/meter-AIF-1.jsonl ]; then ok "cost row staged under .aif/tmp/"; else bad "no staged cost row"; fi

# implement — plus one file the plan never named, to trip scope once
printf 'def users():\n    return []  # impl1\n' > src/app.py
printf '# impl2\n' > src/export.py
printf 'oops\n' > src/oops.py
sgate implement 1 "scope rejects the out-of-plan file"

# The no-progress guard (defects 2/4): a retry that changed nothing is refused;
# a retry that rewrote the diff runs.
sgate implement 4 "an unchanged retry is refused as no progress"
rm -f src/oops.py
sgate implement 0 "the rewritten retry passes green and scope (ledger in diff and all)"

eq "the staged cost row folded into the ledger" \
  "$(jq '[.entries[] | select(.station == "implement" and .agent_id == "cyc-impl-1")] | length' tasks/AIF-1/ledger.json)" "1"
if [ -f .aif/tmp/meter-AIF-1.jsonl ]; then bad "stage file not consumed"; else ok "stage file consumed by the fold"; fi
"$AIF" _commit implement AIF-1 >/dev/null

eq "state: round one reaches done" "$(nextof)" "done"
eq "round-one checklist carries the ticket's gap" \
  "$("$AIF" _state AIF-1 | jq -c '[.next.checklist[] | .source + ":" + .id]')" '["ticket:VG-001"]'

# =============================== ROUND TWO ==================================
printf '\nround two — rework over the finished work\n'

# The reviewer wanted a manifest line. The analyst adds a criterion; nothing
# else is touched, and nothing is reset by hand.
write_ticket ',
    { "id": "AC-003", "surface": "export",
      "given": "the export ran", "when": "the output is read",
      "then": "writes the manifest marker", "expect": "impl3" }'
eq "rework lapses the plan on its own (state back to plan)" "$(nextof)" "plan"

# And a ticket edited into an UNREADY state is caught by the same gate, live —
# the worker would report it, not guess at it.
cp tasks/AIF-1/ticket.md /tmp/aif-cycle-ticket.bak
tmp="$(mktemp)"
meta="$(sed -n '/^<!-- aif:meta$/,/^-->$/p' tasks/AIF-1/ticket.md | sed '1d;$d' |
  jq -c '.open = [{ id: "Q-001", question: "should the manifest be signed?", default: "no" }]')"
rest="$(awk 'body { print } /^-->$/ { body = 1 }' tasks/AIF-1/ticket.md)"
{ printf '<!-- aif:meta\n%s\n-->\n' "$meta"; printf '%s\n' "$rest"; } > tasks/AIF-1/ticket.md
eq "an open question makes the ticket not-ready" "$(nextkind)" "not-ready"
eq "and the question is in the detail, with its default" \
  "$("$AIF" _state AIF-1 | jq -r '.next.detail' | grep -c 'open question Q-001.*default: no')" "1"
cp /tmp/aif-cycle-ticket.bak tasks/AIF-1/ticket.md; rm -f /tmp/aif-cycle-ticket.bak
eq "answered, it is ready again" "$(nextof)" "plan"

TH="$(binding ticket_sha256)"
eq "bindings carry the reworked ticket's hash" "$TH" "$(sha tasks/AIF-1/ticket.md)"
# Defect 10's route: the file round one CREATED is named honestly as
# files.change — it exists now, and this plan is written against the
# repository as it stands.
write_plan "$TH" '[]' '["src/app.py", "src/export.py"]' '["tests/t1.py", "tests/t2.py", "tests/t3.py"]' \
  '{ "AC-001": ["src/app.py", "src/export.py"], "AC-002": ["src/app.py", "src/export.py"], "AC-003": ["src/app.py", "src/export.py"] }' \
  "plan, round two"
sgate plan 0 "plan-form admits the round-two plan (created file now in files.change)"
PJ="$(binding subject_sha256)"
jq -n --arg s "$PJ" '{schema:1,gate:"plan-judge",subject:"plan.md",subject_sha256:$s,
  judge_agent:"aif-plan-judge",at:"t",guesses:[],missing_files:[]}' \
  > tasks/AIF-1/verdict-plan.json
sgate plan-judge 0 "round-two plan judged"
"$AIF" _commit plan AIF-1 >/dev/null

# Defect 3: the round-one lock binds the round-one plan. With the plan
# replaced, the recorded verify-red pass must lapse — tests, not implement.
eq "a stale tests.lock does not route forward (state says tests)" "$(nextof)" "tests"

printf '# AC-003 asserts impl3\n' > tests/t3.py
sgate tests 0 "verify-red admits one red test and two green-at-freeze"
eq "round-two covering is the one red test" \
  "$(jq -c '.covering' tasks/AIF-1/tests.lock.json)" '["t3"]'
eq "green-at-freeze names the round-one tests" \
  "$(jq -c '.green_at_freeze | sort' tasks/AIF-1/tests.lock.json)" '["t1","t2"]'
"$AIF" _commit tests AIF-1 >/dev/null

eq "state: routes to implement" "$(nextof)" "implement"
printf 'def users():\n    return []  # impl1 impl3\n' > src/app.py
sgate implement 0 "round-two implementation passes green and scope"
"$AIF" _commit implement AIF-1 >/dev/null

eq "state: round two reaches done" "$(nextof)" "done"
eq "the closing checklist carries the green-at-freeze tests" \
  "$("$AIF" _state AIF-1 | jq -c '[.next.checklist[] | select(.source == "tests") | .id] | sort')" \
  '["t1","t2"]'

# The drawing: what the ticket decided by default is visible in it, at no cost.
eq "explain draws the default decision" \
  "$("$AIF" explain AIF-1 --ticket --format tree | grep -c 'BY DEFAULT')" "1"

# ----------------------------------------------------------------------------
printf '\n'
rm -f "$TR"
if [ "$fails" -eq 0 ]; then
  printf 'cycle: ok\n'
  cd / && rm -rf "$SANDBOX"
else
  printf 'cycle: %s failure(s) — sandbox kept at %s\n' "$fails" "$SANDBOX"
  exit 1
fi
