#!/bin/sh
# verify.sh — Phase 0 smoke test (and future regression gate)
#
# Usage:
#   ./scripts/verify.sh [jvmtop_jar] [jdk8_home] [jdk21_home]
#
# Defaults (relative to repo root):
#   jvmtop_jar  = upstream/target/jvmtop.jar   (Phase 0: original)
#                 src/target/jvmtop.jar          (Phase 1+: ported)
#   jdk8_home   = jdk/jdk8
#   jdk21_home  = jdk/jdk21
#
# Exit 0 = pass, non-zero = fail.
# All output goes to stdout; errors to stderr.

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

JVMTOP_JAR="${1:-$REPO_ROOT/upstream/target/jvmtop.jar}"
JDK8_HOME="${2:-$REPO_ROOT/jdk/jdk8}"
JDK21_HOME="${3:-$REPO_ROOT/jdk/jdk21}"

JAVA8="$JDK8_HOME/bin/java"
JAVA21="$JDK21_HOME/bin/java"
TOOLS_JAR="$JDK8_HOME/lib/tools.jar"

# ── helpers ──────────────────────────────────────────────────────────────────
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
info() { echo "INFO: $*"; }

# ── preflight ────────────────────────────────────────────────────────────────
[ -x "$JAVA8"  ] || fail "JDK 8 not found at $JDK8_HOME"
[ -x "$JAVA21" ] || fail "JDK 21 not found at $JDK21_HOME"
[ -f "$JVMTOP_JAR" ] || fail "jvmtop jar not found: $JVMTOP_JAR"

info "Using jvmtop: $JVMTOP_JAR"
info "Using JDK 8 : $JDK8_HOME"
info "Using JDK 21: $JDK21_HOME"

# ── compile victim ────────────────────────────────────────────────────────────
VICTIM_DIR="$REPO_ROOT/victim"
VICTIM_CLASS="$VICTIM_DIR/CpuBurner.class"

# Detect which Java to compile victim with (use JDK 21 for Phase 2+ test)
# Phase 0 baseline: compile with JDK 8
VICTIM_JAVA="${VICTIM_JAVA:-$JAVA8}"
info "Compiling victim with: $VICTIM_JAVA"
"$JDK8_HOME/bin/javac" "$VICTIM_DIR/CpuBurner.java" -d "$VICTIM_DIR/" 2>&1 \
  || fail "Failed to compile CpuBurner.java"

# ── start victim ──────────────────────────────────────────────────────────────
info "Starting victim (CpuBurner)..."
"$VICTIM_JAVA" -cp "$VICTIM_DIR" CpuBurner &
VICTIM_PID=$!
info "Victim PID: $VICTIM_PID"

# wait for hsperfdata
WAIT=0
while [ $WAIT -lt 10 ]; do
  if ls /tmp/hsperfdata_*/$VICTIM_PID 2>/dev/null | grep -q .; then
    break
  fi
  sleep 1
  WAIT=$((WAIT+1))
done
info "hsperfdata ready after ${WAIT}s"

cleanup() {
  kill $VICTIM_PID 2>/dev/null || true
}
trap cleanup EXIT

# ── build jvmtop classpath ────────────────────────────────────────────────────
# Phase 0: original jar needs tools.jar
# Phase 1+: ported jar does not need tools.jar
if [ -f "$TOOLS_JAR" ] && echo "$JVMTOP_JAR" | grep -q "upstream"; then
  JT_CP="$JVMTOP_JAR:$TOOLS_JAR"
  JT_JAVA="$JAVA8"
else
  JT_CP="$JVMTOP_JAR"
  JT_JAVA="$JAVA21"
fi

# ── §6.3 check 1: victim visible in overview ─────────────────────────────────
info "Running jvmtop overview (n=2, d=3)..."
OVERVIEW=$(timeout 30 "$JT_JAVA" -cp "$JT_CP" com.jvmtop.JvmTop -n 2 -d 3 -w 120 2>&1 | cat)
echo "$OVERVIEW"

echo "$OVERVIEW" | grep -q "$VICTIM_PID" \
  || fail "Victim PID $VICTIM_PID not visible in overview"
pass "§6.3-1: Victim visible in overview"

# ── §6.3 check 4: heap/nonheap in overview row for victim ────────────────────
# Overview format: PID MAIN-CLASS HPCUR HPMAX NHCUR NHMAX CPU GC VM USERNAME #T DL
# HPCUR and NHCUR should be non-zero (e.g. "7m", "10m") for a live JVM.
VICTIM_ROW=$(echo "$OVERVIEW" | grep "^[[:space:]]*$VICTIM_PID ")
info "Victim overview row: $VICTIM_ROW"

echo "$VICTIM_ROW" | grep -qE '[1-9][0-9]*m' \
  || fail "§6.3-4: heap/nonheap value missing or zero for victim in overview"
pass "§6.3-4: heap/nonheap values non-zero in overview row"

# ── §6.3 check 2+3+5: thread detail ─────────────────────────────────────────
info "Running jvmtop thread detail for PID $VICTIM_PID (n=3, d=4, all threads)..."
DETAIL=$(timeout 40 "$JT_JAVA" -cp "$JT_CP" com.jvmtop.JvmTop -n 3 -d 4 -w 120 --disable-threadlimit $VICTIM_PID 2>&1 | cat)
echo "$DETAIL"

# check 2a: CPU-BURNER present
echo "$DETAIL" | grep -q "CPU-BURNER" \
  || fail "§6.3-2: CPU-BURNER thread not found in detail view"
pass "§6.3-2a: CPU-BURNER thread visible"

# check 2b: CPU-BURNER RUNNABLE
echo "$DETAIL" | grep "CPU-BURNER" | grep -q "RUNNABLE" \
  || fail "§6.3-2: CPU-BURNER thread not RUNNABLE"
pass "§6.3-2b: CPU-BURNER thread is RUNNABLE"

# check 2c: IDLE-MAIN present
echo "$DETAIL" | grep -q "IDLE-MAIN" \
  || fail "§6.3-2: IDLE-MAIN thread not found"
pass "§6.3-2c: IDLE-MAIN thread visible"

# check 3: TOTALCPU for CPU-BURNER > 50%
# Thread detail line format: TID NAME STATE CPU% TOTALCPU%
# Extract TOTALCPU (last % value on CPU-BURNER line) using grep -o | tail -1
TOTALCPU=$(echo "$DETAIL" | grep "CPU-BURNER" | tail -1 \
           | grep -oE '[0-9]+\.[0-9]+%' | tail -1 | tr -d '%')
info "CPU-BURNER TOTALCPU: ${TOTALCPU}%"
echo "$TOTALCPU" | awk '{if ($1+0 > 50) exit 0; else exit 1}' \
  || fail "§6.3-3: CPU-BURNER TOTALCPU ${TOTALCPU}% not > 50%"
pass "§6.3-3: CPU-BURNER TOTALCPU ${TOTALCPU}% > 50%"

# check 4 (detail): HEAP and NONHEAP lines present and non-zero
echo "$DETAIL" | grep -qE 'HEAP:[[:space:]]+[1-9][0-9]*m' \
  || fail "§6.3-4: HEAP value missing or zero in thread detail"
pass "§6.3-4: HEAP value present and non-zero in detail"

echo "$DETAIL" | grep -qE 'NONHEAP:[[:space:]]+[1-9][0-9]*m' \
  || fail "§6.3-4: NONHEAP value missing or zero in thread detail"
pass "§6.3-4: NONHEAP value present and non-zero in detail"

# check 5: no attach error
echo "$DETAIL" | grep -qi "ERROR.*attach\|Could not attach" \
  && fail "§6.3-5: Attach error detected in output"
pass "§6.3-5: No attach error"

# ── §6.3 check 6: launcher options ───────────────────────────────────────────
LAUNCHER="$REPO_ROOT/src/main/wrappers/jvmtop.sh"
[ -f "$LAUNCHER" ] || fail "§6.3-6: jvmtop.sh not found at $LAUNCHER"

grep -q "\-\-add-opens\|\-\-add-exports" "$LAUNCHER" \
  && fail "§6.3-6: jvmtop.sh contains unexpected --add-opens/--add-exports"
pass "§6.3-6: jvmtop.sh has no --add-opens/--add-exports"

grep -q "allowAttachSelf=true" "$LAUNCHER" \
  || fail "§6.3-6: jvmtop.sh missing -Djdk.attach.allowAttachSelf=true"
pass "§6.3-6: jvmtop.sh contains -Djdk.attach.allowAttachSelf=true (§6.3-6 justified)"

# Exclude comment lines so that "removed tools.jar" in a comment does not false-positive
grep -v "^[[:space:]]*#" "$LAUNCHER" | grep -q "tools\.jar" \
  && fail "§6.3-6: jvmtop.sh still references tools.jar (must be removed for JDK 21)"
pass "§6.3-6: jvmtop.sh has no tools.jar reference"

echo ""
echo "============================================"
echo " ALL §6.3 CHECKS PASSED"
echo "============================================"
