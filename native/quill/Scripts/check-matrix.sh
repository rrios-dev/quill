#!/bin/bash
#
# Checks a matrix file (SPIKES.md, QA.md): every row of every table with a "State"
# column has a valid state, and the states that need a note have one (PLAN §1).
#
#   Scripts/check-matrix.sh [--release] <file>...
#
# Valid states: pass, limitation, fail, pending, n/a. A fail or an n/a needs a note
# (the Note column, or the last column when there is none). With --release, pending
# and fail rows are errors too: the release gate accepts only pass, limitation, n/a.
set -euo pipefail

RELEASE=0
if [ "${1:-}" = "--release" ]; then RELEASE=1; shift; fi
[ $# -gt 0 ] || { echo "usage: check-matrix.sh [--release] <file>..." >&2; exit 64; }

status=0
for file in "$@"; do
  [ -f "$file" ] || { echo "✗ $file: not found" >&2; status=1; continue; }
  if ! awk -v release="$RELEASE" -v file="$file" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function cells(line, out,   n, i, parts) {
      line = trim(line); sub(/^\|/, "", line); sub(/\|$/, "", line)
      n = split(line, parts, /\|/)
      for (i = 1; i <= n; i++) out[i] = trim(parts[i])
      return n
    }
    /^\|/ {
      n = cells($0, c)
      if (!intable) {
        intable = 1; statecol = 0; notecol = 0; rowcol = 0; header = 1
        for (i = 1; i <= n; i++) {
          if (c[i] == "State") statecol = i
          if (c[i] == "Note") notecol = i
          if (c[i] == "Row") rowcol = i
        }
        if (notecol == 0) notecol = n
        next
      }
      if (header) { header = 0; next }          # the |---| separator
      if (!statecol) next
      tables++
      row = rowcol ? c[rowcol] : c[1]
      state = c[statecol]; note = c[notecol]
      if (state !~ /^(pass|limitation|fail|pending|n\/a)$/) {
        printf "✗ %s:%d: row %s has state \"%s\"\n", file, NR, row, state; bad++; next
      }
      if ((state == "fail" || state == "n/a") && (note == "" || note == "—" || note == "-")) {
        printf "✗ %s:%d: row %s is %s with no note\n", file, NR, row, state; bad++
      }
      if (release && (state == "pending" || state == "fail")) {
        printf "✗ %s:%d: row %s is %s (release gate)\n", file, NR, row, state; bad++
      }
      counts[state]++
      next
    }
    { intable = 0 }
    END {
      if (tables == 0) { printf "✗ %s: no matrix rows (no table with a State column)\n", file; exit 1 }
      summary = ""
      for (s in counts) summary = summary sprintf(" %s=%d", s, counts[s])
      if (bad) exit 1
      printf "✓ %s: %d rows:%s\n", file, tables, summary
    }
  ' "$file"; then
    status=1
  fi
done
exit $status
