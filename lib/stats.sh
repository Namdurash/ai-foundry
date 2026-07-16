#!/usr/bin/env bash
#
# Statistics for eval runs. Everything goes through awk because bash has no
# floating point.
#
# Sourced by bin/aif; not meant to be executed directly.

# aif_stats_wilson <passes> <runs> — "60% [23-88%]"
#
# Wilson score interval, not the normal approximation. At the run counts anyone
# will actually use (3-5), the normal approximation produces intervals below 0%
# and reports 5/5 as "100% +/- 0%" — which is exactly the lie that makes people
# trust a flaky set. Wilson degrades honestly: 5/5 comes out as 100% [57-100%],
# correctly saying "you have not proven much yet".
aif_stats_wilson() {
  awk -v k="$1" -v n="$2" 'BEGIN {
    if (n == 0) { printf "n/a"; exit }
    z = 1.96
    p = k / n
    d = 1 + z*z/n
    centre = (p + z*z/(2*n)) / d
    margin = z * sqrt(p*(1-p)/n + z*z/(4*n*n)) / d
    lo = centre - margin
    hi = centre + margin
    if (lo < 0) lo = 0
    if (hi > 1) hi = 1
    printf "%.0f%% [%.0f-%.0f%%]", p*100, lo*100, hi*100
  }'
}

# aif_stats_sum <field-index> — sum a column of TSV on stdin.
aif_stats_sum() {
  awk -v f="$1" '{ s += $f } END { printf "%.4f", s + 0 }'
}

# aif_stats_median <field-index> — median of a TSV column on stdin.
aif_stats_median() {
  awk -v f="$1" '
    { v[n++] = $f }
    END {
      if (n == 0) { printf "0"; exit }
      # Insertion sort: n is the number of runs, so single digits.
      for (i = 1; i < n; i++) {
        x = v[i]
        for (j = i - 1; j >= 0 && v[j] > x; j--) v[j+1] = v[j]
        v[j+1] = x
      }
      if (n % 2) printf "%g", v[(n-1)/2]
      else printf "%g", (v[n/2 - 1] + v[n/2]) / 2
    }'
}
