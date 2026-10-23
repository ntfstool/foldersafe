#!/usr/bin/env bash
# Runs the Cryptomator interop harness (TEST ONLY, AGPL dependencies — see README.md).
# Usage: interop/cryptomator/run.sh <create|dump|write|selftest> [options]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# JDK 22 or newer: $JAVA_HOME_22, else macOS java_home (-v 22), else $JAVA_HOME (e.g. set by CI's setup-java).
JAVA_HOME_CANDIDATE="${JAVA_HOME_22:-}"
[ -n "$JAVA_HOME_CANDIDATE" ] && [ -x "$JAVA_HOME_CANDIDATE/bin/java" ] || JAVA_HOME_CANDIDATE="$(/usr/libexec/java_home -v 22 2>/dev/null || true)"
[ -n "$JAVA_HOME_CANDIDATE" ] && [ -x "$JAVA_HOME_CANDIDATE/bin/java" ] || JAVA_HOME_CANDIDATE="${JAVA_HOME:-}"
[ -n "$JAVA_HOME_CANDIDATE" ] && [ -x "$JAVA_HOME_CANDIDATE/bin/java" ] || { echo "error: JDK 22+ not found (set JAVA_HOME_22 or JAVA_HOME)" >&2; exit 1; }
export JAVA_HOME="$JAVA_HOME_CANDIDATE"
JAR="$HERE/target/cryptomator-interop.jar"
if [ ! -f "$JAR" ]; then
  MVN="$(command -v mvn || echo /opt/homebrew/bin/mvn)"
  "$MVN" -q -f "$HERE/pom.xml" package >&2
fi
exec "$JAVA_HOME/bin/java" -jar "$JAR" "$@"
