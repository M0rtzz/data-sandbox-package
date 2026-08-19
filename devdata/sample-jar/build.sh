#!/bin/bash
#
# Build the Z-05 sample JAR (DataDevSample) into devdata/sample-jar/datadev-sample-1.0.0.jar.
#
# Requirements:
#   - JDK 17 (javac + jar)
#
# The produced JAR satisfies the platform JAR contract:
#   - ZIP with META-INF/MANIFEST.MF (Main-Class: com.example.DataDevSample)
#   - CLI: java -jar datadev-sample-1.0.0.jar --input <csv> --output <csv> [--params <json>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${SCRIPT_DIR}/datadev-sample-1.0.0.jar"
BUILD_DIR="$(mktemp -d /tmp/datadev-sample-build.XXXXXX)"
trap 'rm -rf "${BUILD_DIR}"' EXIT

JAVAC="${JAVAC:-javac}"
JAR_BIN="${JAR:-jar}"

"${JAVAC}" -d "${BUILD_DIR}/classes" "${SCRIPT_DIR}/src/com/example/DataDevSample.java"

mkdir -p "${BUILD_DIR}/classes/META-INF"
cat >"${BUILD_DIR}/classes/META-INF/MANIFEST.MF" <<'EOF'
Manifest-Version: 1.0
Main-Class: com.example.DataDevSample
EOF

"${JAR_BIN}" --create --file "${OUT}" --manifest "${BUILD_DIR}/classes/META-INF/MANIFEST.MF" -C "${BUILD_DIR}/classes" com

echo "built ${OUT}"
