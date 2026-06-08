#!/bin/sh
# jvmtop - java monitoring for the command-line
# launch script (JDK 21 port)
#
# Original author: Markus Kolb
# JDK 21 port: removed tools.jar (not present in JDK 9+); added
#   -Djdk.attach.allowAttachSelf=true so jvmtop shows its own process in
#   the overview (matching original golden-reference behaviour — §6.3-6
#   justified minimal option, see docs/PHASE0_ANALYSIS.md §8).
#
DIR=$(cd "$(dirname "$0")" && pwd -P)

if [ -z "$JAVA_HOME" ]; then
  JAVA_HOME=$(readlink -f "$(which java 2>/dev/null)" 2>/dev/null | sed 's|/bin/java||')
fi

if [ -z "$JAVA_HOME" ] || [ ! -x "$JAVA_HOME/bin/java" ]; then
  echo "Cannot find java. Set JAVA_HOME to a JDK 21+ installation." >&2
  exit 1
fi

exec "$JAVA_HOME/bin/java" \
  -Djdk.attach.allowAttachSelf=true \
  $JAVA_OPTS \
  -cp "$DIR/jvmtop.jar" \
  com.jvmtop.JvmTop "$@"
