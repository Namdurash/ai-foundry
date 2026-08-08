#!/usr/bin/env bash
#
# `aif cost [<ticket>]` — what the pipeline spent, read out of the ledgers.
# Sourced by bin/aif; not meant to be executed directly.
#
# The ledger has recorded per-station tokens since metering moved into a
# SubagentStop hook, but nothing ever added them up, so the answer to "what did
# this ticket cost" was a jq expression the user had to write. A number nobody
# can see is not an accounting; this is the readout.
#
# Three rules, all of them about not producing a comfortable number:
#
#   - TOKENS ARE THE TOTAL, dollars are a derivation. lib/ledger.sh records
#     tokens because total_cost_usd is structurally 0 under subscription auth
#     (docs/FINDINGS.md #2), and sets/claude/prices.json ships EMPTY on purpose.
#     So the token columns are always complete and the usd column often is not.
#   - AN INCOMPLETE TOTAL SAYS SO. A station whose model is absent from the price
#     table contributes 0 dollars to the sum, which would read as cheap. Such a
#     total prints as a lower bound (>=) and the missing models are named, since
#     the fix is one file away.
#   - UNMETERED ATTEMPTS ARE COUNTED, not skipped. cmd_meter records a station
#     that left no readable transcript as `unmetered` rather than dropping it;
#     hiding those rows here would undo that on the way out and make a ticket
#     with a broken hook look like a cheap one.

# _aif_cost_roll <ledger> — one ticket's roll-up, as JSON.
#
# Station order is first-appearance, not sorted: the pipeline has an order, and
# reading spend in that order shows WHERE the money went. group_by would
# alphabetise and put implement before plan.
_aif_cost_roll() {
  jq '
    [ .entries[] | select(.station != null) ] as $rows
    | ( $rows | map(.station)
        | reduce .[] as $x ([]; if index($x) == null then . + [$x] else . end) ) as $names
    | ( [ $names[] as $n
          | ( $rows | map(select(.station == $n)) ) as $g
          | { label:       $n,
              attempts:    ( $g | length ),
              unmetered:   ( $g | map(select(.result == "unmetered")) | length ),
              unpriced:    ( $g | map(select(.result == "ran" and .cost_usd == null)) | length ),
              turns:       ( $g | map(.num_turns // 0) | add ),
              input:       ( $g | map(.usage.input_tokens                // 0) | add ),
              output:      ( $g | map(.usage.output_tokens               // 0) | add ),
              cache_read:  ( $g | map(.usage.cache_read_input_tokens     // 0) | add ),
              cache_write: ( $g | map(.usage.cache_creation_input_tokens // 0) | add ),
              usd:         ( $g | map(.cost_usd // 0) | add ) } ] ) as $st
    | { ticket: .ticket,
        rows: $st,
        total: { label:       "total",
                 rows:        ( $st | length ),
                 attempts:    ( [ $st[].attempts    ] | add // 0 ),
                 unmetered:   ( [ $st[].unmetered   ] | add // 0 ),
                 unpriced:    ( [ $st[].unpriced    ] | add // 0 ),
                 turns:       ( [ $st[].turns       ] | add // 0 ),
                 input:       ( [ $st[].input       ] | add // 0 ),
                 output:      ( [ $st[].output      ] | add // 0 ),
                 cache_read:  ( [ $st[].cache_read  ] | add // 0 ),
                 cache_write: ( [ $st[].cache_write ] | add // 0 ),
                 usd:         ( [ $st[].usd         ] | add // 0 ) },
        # Named, not counted: these are the exact keys prices.json is missing. A
        # bare count would say "incomplete" without saying incomplete of what.
        models_unpriced:
          ( $rows | map(select(.result == "ran" and .cost_usd == null) | .model // empty)
                  | unique ) }
  ' "$1" 2>/dev/null
}

# _aif_cost_table <first-column-header> — TSV on stdin, aligned table on stdout.
#
# Columns in: label, attempts, turns, input, output, cache_read, cache_write,
# usd, unpriced. The last two collapse into one rendered dollar cell.
#
# awk because bash has no floating point and no column arithmetic, and because
# the dollar rule belongs in exactly one place — splitting it between jq and bash
# is how two copies of a rounding rule start disagreeing.
_aif_cost_table() {
  awk -F'\t' -v dim="$AIF_C_DIM" -v reset="$AIF_C_RESET" -v bold="$AIF_C_BOLD" \
      -v lead="$1" '
    function commify(n,   s, out, i, len) {
      s = sprintf("%d", n); len = length(s); out = ""
      for (i = 1; i <= len; i++) {
        out = out substr(s, i, 1)
        if ((len - i) % 3 == 0 && i < len) out = out ","
      }
      return out
    }
    # A wholly unpriced row is not a number at all: printing the 0 that an absent
    # price contributes would be a confident wrong figure, which is the one thing
    # this readout must never emit.
    function usd_cell(usd, unpriced) {
      if (usd + 0 == 0) return "-"
      if (unpriced + 0 > 0) return sprintf(">=%.4f", usd)
      return sprintf("%.4f", usd)
    }
    BEGIN {
      h[1] = lead; h[2] = "att"; h[3] = "turns"; h[4] = "input"
      h[5] = "output";  h[6] = "cache rd"; h[7] = "cache wr"; h[8] = "usd"
      for (c = 1; c <= 8; c++) w[c] = length(h[c])
    }
    {
      n++
      istotal[n] = ($1 == "total")
      for (c = 1; c <= 7; c++) {
        v = (c == 1) ? $c : commify($c)
        cell[n, c] = v
        if (length(v) > w[c]) w[c] = length(v)
      }
      v = usd_cell($8, $9)
      cell[n, 8] = v
      if (length(v) > w[8]) w[8] = length(v)
    }
    END {
      line = sprintf("  %s%-*s", dim, w[1], h[1])
      for (c = 2; c <= 8; c++) line = line sprintf("  %*s", w[c], h[c])
      print line reset
      for (r = 1; r <= n; r++) {
        if (istotal[r]) {
          rule = "  "
          for (c = 1; c <= 8; c++) {
            for (i = 0; i < w[c]; i++) rule = rule "-"
            if (c < 8) rule = rule "  "
          }
          print dim rule reset
        }
        line = sprintf("  %s%-*s", (istotal[r] ? bold : ""), w[1], cell[r, 1])
        for (c = 2; c <= 8; c++) line = line sprintf("  %*s", w[c], cell[r, c])
        print line (istotal[r] ? reset : "")
      }
    }'
}

# _aif_cost_render <roll> <first-column-header> — the table, rows then total.
_aif_cost_render() {
  printf '%s' "$1" | jq -r '
    ( .rows[], .total )
    | [ .label, .attempts, .turns, .input, .output, .cache_read, .cache_write,
        .usd, .unpriced ] | @tsv' | _aif_cost_table "$2"
}

# _aif_cost_notes <roll> — what the table cannot say in a column.
_aif_cost_notes() {
  local roll="$1" unmetered unpriced models
  printf '\n'

  # Zero attempts is not "clean" — it is no data. Falling through to the all-clear
  # line below would report a table of zeroes as a metered, priced pipeline, which
  # is the single most flattering thing this readout could say.
  if [ "$(printf '%s' "$roll" | jq -r '.total.attempts')" -eq 0 ]; then
    printf '  %sno station costs recorded anywhere%s — the metering hook has never run.\n' \
      "$AIF_C_YELLOW" "$AIF_C_RESET"
    printf '  %sThe zeroes above are missing data, not a cheap pipeline.%s\n' \
      "$AIF_C_DIM" "$AIF_C_RESET"
    # shellcheck disable=SC2016 # the backticks are prose, not a substitution
    printf '  %sSee `aif cost <ticket>` for which tickets ran, and re-run `aif init`.%s\n\n' \
      "$AIF_C_DIM" "$AIF_C_RESET"
    return 0
  fi

  unmetered="$(printf '%s' "$roll" | jq -r '.total.unmetered')"
  if [ "$unmetered" -gt 0 ]; then
    printf '  %s%s attempt(s) ran UNMETERED%s — their tokens are missing from every column\n' \
      "$AIF_C_YELLOW" "$unmetered" "$AIF_C_RESET"
    printf '  %sabove, so the totals are low by an unknown amount.%s\n' \
      "$AIF_C_DIM" "$AIF_C_RESET"
  fi

  unpriced="$(printf '%s' "$roll" | jq -r '.total.unpriced')"
  if [ "$unpriced" -gt 0 ]; then
    models="$(printf '%s' "$roll" | jq -r '.models_unpriced | join(", ")')"
    # Deliberately NOT "these models are missing from prices.json" — cmd_meter
    # prices a row when the station is metered, and the ledger is append-only, so
    # a row recorded before the table had that model stays null forever. Claiming
    # the model is absent would be checkably false the moment someone adds it and
    # the warning persists. What is true is that the ROW carries no price.
    printf '  %sdollars are incomplete%s — %s attempt(s) recorded no price (%s%s%s)\n' \
      "$AIF_C_YELLOW" "$AIF_C_RESET" "$unpriced" \
      "$AIF_C_BOLD" "${models:-unknown model}" "$AIF_C_RESET"
    printf '  %sThe token columns are complete. Pricing happens when a station is metered\n' \
      "$AIF_C_DIM"
    printf '  and is never backfilled, so filling .aif/prices.json only affects later runs.%s\n' \
      "$AIF_C_RESET"
  fi

  if [ "$unmetered" -eq 0 ] && [ "$unpriced" -eq 0 ]; then
    printf '  %severy attempt metered and priced%s\n' "$AIF_C_DIM" "$AIF_C_RESET"
  fi
  printf '\n'
}

# _aif_cost_empty <ledger> — explain a ledger with no station rows.
#
# Zero station rows is indistinguishable from "nothing ran" if reported as an
# empty table, and the two have opposite fixes. The gate rows tell them apart:
# gates recorded but stations not means the metering hook, not an idle ticket.
_aif_cost_empty() {
  local gates
  gates="$(jq '[.entries[] | select(.gate != null)] | length' "$1" 2>/dev/null || printf 0)"

  printf '  %sno station costs recorded%s\n' "$AIF_C_YELLOW" "$AIF_C_RESET"
  if [ "$gates" -gt 0 ]; then
    printf '  %s%s gate results are here, so this ticket ran — but nothing metered it.%s\n' \
      "$AIF_C_DIM" "$gates" "$AIF_C_RESET"
    printf '  %sThe SubagentStop hook must be registered in .claude/settings.json AND%s\n' \
      "$AIF_C_DIM" "$AIF_C_RESET"
    # shellcheck disable=SC2016 # the backticks are prose, not a substitution
    printf '  %s.aif/hooks/meter.sh must be executable. `aif init` repairs both.%s\n' \
      "$AIF_C_DIM" "$AIF_C_RESET"
  else
    printf '  %sno gate results either — this ticket has not run.%s\n' \
      "$AIF_C_DIM" "$AIF_C_RESET"
  fi
  printf '\n'
}

# _aif_cost_one <root> <ticket> — the per-station readout for one ticket.
_aif_cost_one() {
  local root="$1" ticket="$2" work ledger roll
  work="$(aif_task_dir "$root" "$ticket")"
  ledger="$(aif_ledger_path "$work")"

  [ -f "$ledger" ] ||
    aif_die "no ledger at $AIF_TASKS_DIR/$ticket/ledger.json — has this ticket run?"

  roll="$(_aif_cost_roll "$ledger")"
  printf '%s' "$roll" | jq -e . >/dev/null 2>&1 ||
    aif_die "could not read $AIF_TASKS_DIR/$ticket/ledger.json — not valid JSON?"

  if [ "$AIF_COST_JSON" -eq 1 ]; then
    printf '%s\n' "$roll" | jq .
    return 0
  fi

  printf '\n%s%s%s\n\n' "$AIF_C_BOLD" "$ticket" "$AIF_C_RESET"

  if [ "$(printf '%s' "$roll" | jq -r '.total.rows')" -eq 0 ]; then
    _aif_cost_empty "$ledger"
    return 0
  fi

  _aif_cost_render "$roll" station
  _aif_cost_notes "$roll"
}

# _aif_cost_all <root> — one line per ticket, plus a grand total.
#
# The same roll-up shape as a single ticket, with tickets standing in for
# stations, so both views share _aif_cost_render and _aif_cost_notes. Tickets
# with no ledger are skipped silently: a scaffolded ticket that never ran has
# nothing to report and is not a gap in the accounting.
_aif_cost_all() {
  local root="$1" dir ticket ledger roll tsv roll_all
  tsv="$(mktemp "${TMPDIR:-/tmp}/aif-cost-XXXXXX")"

  for dir in "$root/$AIF_TASKS_DIR"/*; do
    [ -d "$dir" ] || continue
    ticket="$(basename "$dir")"
    ledger="$(aif_ledger_path "$dir")"
    [ -f "$ledger" ] || continue
    roll="$(_aif_cost_roll "$ledger")"
    printf '%s' "$roll" | jq -e . >/dev/null 2>&1 || continue
    printf '%s' "$roll" |
      jq -c --arg t "$ticket" '.total + { label: $t, models_unpriced: .models_unpriced }' \
      >>"$tsv"
  done

  if [ ! -s "$tsv" ]; then
    rm -f "$tsv"
    aif_die "no ledgers under $AIF_TASKS_DIR/ — nothing has run yet"
  fi

  roll_all="$(jq -s '. as $t
    | { rows: $t,
        total: { label:       "total",
                 rows:        ( $t | length ),
                 attempts:    ( [ $t[].attempts    ] | add // 0 ),
                 unmetered:   ( [ $t[].unmetered   ] | add // 0 ),
                 unpriced:    ( [ $t[].unpriced    ] | add // 0 ),
                 turns:       ( [ $t[].turns       ] | add // 0 ),
                 input:       ( [ $t[].input       ] | add // 0 ),
                 output:      ( [ $t[].output      ] | add // 0 ),
                 cache_read:  ( [ $t[].cache_read  ] | add // 0 ),
                 cache_write: ( [ $t[].cache_write ] | add // 0 ),
                 usd:         ( [ $t[].usd         ] | add // 0 ) },
        models_unpriced: ( [ $t[].models_unpriced[]? ] | unique ) }' "$tsv")"
  rm -f "$tsv"

  if [ "$AIF_COST_JSON" -eq 1 ]; then
    printf '%s\n' "$roll_all" | jq .
    return 0
  fi

  printf '\n%sall tickets%s\n\n' "$AIF_C_BOLD" "$AIF_C_RESET"
  _aif_cost_render "$roll_all" ticket
  _aif_cost_notes "$roll_all"
  printf '  %sPer-station breakdown: aif cost <ticket>%s\n\n' "$AIF_C_DIM" "$AIF_C_RESET"
}

aif_cmd_cost() {
  local ticket=""
  AIF_COST_JSON=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --json) AIF_COST_JSON=1 ;;
      -h | --help)
        cat <<'EOF'
usage: aif cost [<ticket>] [--json]

What the pipeline spent, per station, out of the ticket's ledger. With no
ticket, one line per ticket under tasks/ plus a grand total.

Tokens are the recorded datum and are always complete. Dollars are derived
from .aif/prices.json, which ships empty on purpose — an unpriced station
shows its tokens and no dollar figure rather than a wrong one. A total that
includes an unpriced station is marked ">=".
EOF
        return 0
        ;;
      -*) aif_die "unknown option: $1" ;;
      *) [ -n "$ticket" ] || ticket="$1" ;;
    esac
    shift
  done

  aif_have jq || aif_die "jq is required to read the ledger"

  local root
  root="$(aif_require_project)"

  if [ -n "$ticket" ]; then
    _aif_cost_one "$root" "$ticket"
  else
    _aif_cost_all "$root"
  fi
}
