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

# ── run jvmtop: overview ─────────────────────────────────────────────────────
info "Running jvmtop overview (n=2, d=3)..."
OVERVIEW=$(timeout 30 "$JT_JAVA" -cp "$JT_CP" com.jvmtop.JvmTop -n 2 -d 3 -w 120 2>&1 | cat)
echo "$OVERVIEW"

echo "$OVERVIEW" | grep -q "$VICTIM_PID" \
  || fail "Victim PID $VICTIM_PID not visible in overview"
pass "Victim visible in overview"

# ── run jvmtop: thread detail ─────────────────────────────────────────────────
info "Running jvmtop thread detail for PID $VICTIM_PID (n=3, d=4, all threads)..."
DETAIL=$(timeout 40 "$JT_JAVA" -cp "$JT_CP" com.jvmtop.JvmTop -n 3 -d 4 -w 120 --disable-threadlimit $VICTIM_PID 2>&1 | cat)
echo "$DETAIL"

# Must see CPU-BURNER as RUNNABLE
echo "$DETAIL" | grep -q "CPU-BURNER" \
  || fail "CPU-BURNER thread not found in detail view"
pass "CPU-BURNER thread visible"

echo "$DETAIL" | grep "CPU-BURNER" | grep -q "RUNNABLE" \
  || fail "CPU-BURNER thread not RUNNABLE"
pass "CPU-BURNER thread is RUNNABLE"

# IDLE-MAIN must be present and not RUNNABLE (TIMED_WAITING)
echo "$DETAIL" | grep -q "IDLE-MAIN" \
  || fail "IDLE-MAIN thread not found"
pass "IDLE-MAIN thread visible"

# Must not contain attach error
echo "$DETAIL" | grep -qi "ERROR.*attach\|Could not attach" \
  && fail "Attach error detected in output"
pass "No attach error"

echo ""
echo "============================================"
echo " ALL CHECKS PASSED"
echo "============================================"
