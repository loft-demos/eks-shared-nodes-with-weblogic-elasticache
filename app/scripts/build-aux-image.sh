#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${1:-ghcr.io/YOUR_ORG/vcluster-weblogic-demo-aux:0.1.0}"
WDT_ZIP="${WDT_ZIP:-}"

if [[ -z "$WDT_ZIP" || ! -f "$WDT_ZIP" ]]; then
  echo "Set WDT_ZIP to the WebLogic Deploy Tooling release zip before building." >&2
  echo "Download: https://github.com/oracle/weblogic-deploy-tooling/releases/latest/download/weblogic-deploy.zip" >&2
  echo "Example: WDT_ZIP=/tmp/weblogic-deploy.zip $0 $IMAGE" >&2
  exit 1
fi

"$ROOT_DIR/scripts/build-demo-war.sh"

rm -rf "$ROOT_DIR/build/aux-context"
mkdir -p "$ROOT_DIR/build/aux-context/models"
cp "$ROOT_DIR/build/models/"* "$ROOT_DIR/build/aux-context/models/"
unzip -q "$WDT_ZIP" -d "$ROOT_DIR/build/aux-context"
rm -f "$ROOT_DIR/build/aux-context/weblogic-deploy/bin/"*.cmd
cp "$ROOT_DIR/aux-image/Dockerfile" "$ROOT_DIR/build/aux-context/Dockerfile"

docker build -t "$IMAGE" "$ROOT_DIR/build/aux-context"

echo "$IMAGE"
