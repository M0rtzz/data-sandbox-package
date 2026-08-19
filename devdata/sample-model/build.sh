#!/bin/bash
#
# Build the Z-06 sample model JAR (ModelScorerSample) into devdata/sample-model/model-scorer-sample-1.0.0.jar.
#
# Requirements:
#   - JDK 17 (javac + jar)
#
# The produced JAR satisfies the platform JAR contract:
#   - ZIP with META-INF/MANIFEST.MF (Main-Class: com.example.ModelScorerSample)
#   - CLI: java -jar model-scorer-sample-1.0.0.jar --input <csv> --output <csv> [--params <json>]
#   - 行级 1:1 scorer：输出行数与输入行数一致，prediction 列追加到原列之后
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${SCRIPT_DIR}/model-scorer-sample-1.0.0.jar"
BUILD_DIR="$(mktemp -d /tmp/model-scorer-build.XXXXXX)"
trap 'rm -rf "${BUILD_DIR}"' EXIT

JAVAC="${JAVAC:-javac}"
JAR_BIN="${JAR:-jar}"

"${JAVAC}" -d "${BUILD_DIR}/classes" "${SCRIPT_DIR}/src/com/example/ModelScorerSample.java"

mkdir -p "${BUILD_DIR}/classes/META-INF"
cat >"${BUILD_DIR}/classes/META-INF/MANIFEST.MF" <<'EOF'
Manifest-Version: 1.0
Main-Class: com.example.ModelScorerSample
EOF

"${JAR_BIN}" --create --file "${OUT}" --manifest "${BUILD_DIR}/classes/META-INF/MANIFEST.MF" -C "${BUILD_DIR}/classes" com

echo "built ${OUT}"
