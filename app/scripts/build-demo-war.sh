#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAVEN_IMAGE="${MAVEN_IMAGE:-maven:3.9.9-eclipse-temurin-11}"
USE_LOCAL_MAVEN="${USE_LOCAL_MAVEN:-false}"

if [[ "$USE_LOCAL_MAVEN" == "true" ]]; then
  if ! command -v mvn >/dev/null 2>&1; then
    echo "USE_LOCAL_MAVEN=true was set, but mvn is not installed." >&2
    exit 1
  fi
  (cd "$ROOT_DIR/demo-webapp" && mvn -q package)
else
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is required to build without local Java/Maven." >&2
    echo "Or set USE_LOCAL_MAVEN=true on a machine with Maven installed." >&2
    exit 1
  fi
  docker run --rm \
    -v "$ROOT_DIR/demo-webapp:/workspace" \
    -v "$ROOT_DIR/.m2:/root/.m2" \
    -w /workspace \
    "$MAVEN_IMAGE" \
    mvn -q package
fi

mkdir -p "$ROOT_DIR/build/wlsdeploy/applications"
cp "$ROOT_DIR/demo-webapp/target/demo-webapp-0.1.0.war" "$ROOT_DIR/build/wlsdeploy/applications/demo-webapp.war"

cd "$ROOT_DIR/build"
rm -f archive.zip
zip -qr archive.zip wlsdeploy

mkdir -p "$ROOT_DIR/build/models"
cp "$ROOT_DIR/wdt-models/model.10.yaml" "$ROOT_DIR/build/models/"
cp "$ROOT_DIR/build/archive.zip" "$ROOT_DIR/build/models/archive.zip"

echo "$ROOT_DIR/build/models"
