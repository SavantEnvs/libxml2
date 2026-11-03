#!/usr/bin/env bash
#
# mayhem/test.sh — RUN libxml2's own suites (runtest, runsuite, testrecurse: golden-output comparisons)
# plus known-answer xmllint checks, all built by mayhem/build.sh. Parses the suites' result counts.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


B=mayhem/build-tests
passed=0; failed=0

# Runners that print "Total N tests, no errors" / "Total N tests, E errors, L leaks".
count_suite() {
  local name="$1"; shift
  local out line n e
  out=$("$@" 2>&1); local rc=$?
  line=$(printf '%s\n' "$out" | grep -E '^Total [0-9]+ tests' | tail -1)
  if [ -z "$line" ]; then echo "FAIL $name: no 'Total N tests' line (rc=$rc)" >&2; failed=$((failed+1)); return; fi
  n=$(printf '%s' "$line" | sed -E 's/^Total ([0-9]+) tests.*/\1/')
  if printf '%s' "$line" | grep -q 'no errors' && [ "$rc" -eq 0 ]; then
    passed=$((passed+n)); echo "PASS $name: $line"
  else
    e=$(printf '%s' "$line" | sed -nE 's/.*, ([0-9]+) errors.*/\1/p'); e=${e:-1}
    [ "$e" -ge 1 ] || e=1
    failed=$((failed+e)); passed=$((passed+n-e)); echo "FAIL $name: $line (rc=$rc)" >&2
  fi
}

for t in runtest runsuite testrecurse; do
  [ -x "$B/$t" ] || { echo "missing $B/$t — build.sh must build it" >&2; emit_ctrf libxml2-tests 0 1; exit 1; }
done
count_suite runtest   "$B/runtest" --out "$SRC/mayhem/build-tests"
count_suite runsuite  "$B/runsuite"
count_suite testrecurse "$B/testrecurse"

# Known-answer checks against the xmllint binary.
check() { # name expected actual
  if [ "$2" = "$3" ]; then passed=$((passed+1)); echo "PASS $1"; else failed=$((failed+1)); echo "FAIL $1: expected [$2] got [$3]" >&2; fi
}
X="$B/xmllint"
[ -x "$X" ] || { echo "missing $X" >&2; emit_ctrf libxml2-tests 0 1; exit 1; }
doc='<root xmlns:p="urn:p"><a id="1">hello</a><a id="2">world</a><p:b>x</p:b></root>'
check xpath-string   "world" "$(printf '%s' "$doc" | "$X" --xpath 'string(/root/a[@id="2"])' - 2>/dev/null)"
check xpath-count    "2" "$(printf '%s' "$doc" | "$X" --xpath 'count(//a)' - 2>/dev/null)"
check c14n           '<root xmlns:p="urn:p"><a id="1">hello</a><a id="2">world</a><p:b>x</p:b></root>' "$(printf '%s' '<root  xmlns:p="urn:p" ><a id="1" >hello</a><a  id="2">world</a><p:b>x</p:b></root>' | "$X" --c14n - 2>/dev/null)"
check format         "$(printf '<?xml version="1.0"?>\n<r>\n  <c/>\n</r>')" "$(printf '<r><c/></r>' | "$X" --format - 2>/dev/null)"
printf '<r><c></r>' | "$X" --noout - >/dev/null 2>&1; check wellformed-reject 4 "$?"
tmpd=$(mktemp -d)
printf '<!ELEMENT r (c)><!ELEMENT c EMPTY>' > "$tmpd/r.dtd"
printf '<r><c/></r>' > "$tmpd/ok.xml"; printf '<r><d/></r>' > "$tmpd/bad.xml"
"$X" --noout --dtdvalid "$tmpd/r.dtd" "$tmpd/ok.xml" >/dev/null 2>&1; check dtd-valid 0 "$?"
"$X" --noout --dtdvalid "$tmpd/r.dtd" "$tmpd/bad.xml" >/dev/null 2>&1; check dtd-invalid 3 "$?"
rm -rf "$tmpd"

emit_ctrf libxml2-tests "$passed" "$failed"
