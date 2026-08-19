#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${1:-ghcr.io/loft-demos/vcluster-weblogic-demo-aux:0.1.0}"
WAR="$ROOT_DIR/demo-webapp/target/demo-webapp-0.1.0.war"
ARCHIVE="$ROOT_DIR/build/models/archive.zip"

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "Missing required file: $1" >&2
    exit 1
  fi
}

require_unzip_entry() {
  local zip_file="$1"
  local entry="$2"

  if ! unzip -l "$zip_file" | awk '{print $4}' | grep -qx "$entry"; then
    echo "Missing $entry in $zip_file" >&2
    exit 1
  fi
}

require_file "$WAR"
require_file "$ARCHIVE"

require_unzip_entry "$WAR" "WEB-INF/classes/demo/DemoServlet.class"
require_unzip_entry "$WAR" "WEB-INF/classes/demo/CacheDemoServlet.class"
require_unzip_entry "$WAR" "WEB-INF/classes/demo/CacheConfig.class"
require_unzip_entry "$WAR" "WEB-INF/classes/demo/MiniRedis.class"
# Without this the context root would be /demo-webapp and the HTTPRoute prefix would 404.
require_unzip_entry "$WAR" "WEB-INF/weblogic.xml"
require_unzip_entry "$ARCHIVE" "wlsdeploy/applications/demo-webapp.war"

if ! unzip -p "$WAR" WEB-INF/weblogic.xml | grep -q "<context-root>/demo</context-root>"; then
  echo "weblogic.xml context root is not /demo" >&2
  exit 1
fi

docker image inspect "$IMAGE" >/dev/null

docker run --rm "$IMAGE" sh -c '
  set -eu
  test -f /auxiliary/models/model.10.yaml
  test -f /auxiliary/models/archive.zip
  test -x /auxiliary/weblogic-deploy/bin/validateModel.sh
  grep -q "demo-webapp" /auxiliary/models/model.10.yaml
'

echo "Smoke test OK for $IMAGE"
