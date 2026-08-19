#!/usr/bin/env bash
#
# Downloads the ACK ElastiCache Helm chart straight from ECR Public's registry API.
#
# `helm registry login` against public.ecr.aws fails on macOS when the keychain already
# holds an entry another application owns: the login reports
#   The specified item already exists in the keychain. (-25299)
# and helm then reuses a stale token, so the pull fails with the misleading
#   400 denied: Your Authorization Token is invalid
# `helm registry logout` cannot fix it either (-25244, wrong owner), and even
# --registry-config with a clean file still hits the keychain.
#
# This uses the registry's anonymous token flow instead, which needs no login at all.
#
#   ./fetch-ack-chart.sh              # latest release
#   ACK_VERSION=1.7.1 ./fetch-ack-chart.sh
set -euo pipefail

REPO="${REPO:-aws-controllers-k8s/elasticache-chart}"
OUT_DIR="${OUT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/charts}"

ACK_VERSION="${ACK_VERSION:-$(curl -sL \
  https://api.github.com/repos/aws-controllers-k8s/elasticache-controller/releases/latest \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["tag_name"].lstrip("v"))')}"

mkdir -p "$OUT_DIR"
TGZ="${OUT_DIR}/elasticache-chart-${ACK_VERSION}.tgz"

echo "==> Fetching an anonymous pull token"
TOKEN="$(curl -s "https://public.ecr.aws/token/?scope=repository:${REPO}:pull" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')"

echo "==> Reading the manifest for ${ACK_VERSION}"
MANIFEST="$(curl -s -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.oci.image.manifest.v1+json" \
  "https://public.ecr.aws/v2/${REPO}/manifests/${ACK_VERSION}")"

DIGEST="$(printf '%s' "$MANIFEST" | python3 -c '
import json,sys
m=json.load(sys.stdin)
if "layers" not in m:
    sys.exit("no layers in manifest: " + json.dumps(m)[:200])
for l in m["layers"]:
    if "helm.chart.content" in l["mediaType"]:
        print(l["digest"]); break
else:
    sys.exit("no helm chart layer found")
')"

echo "==> Downloading ${DIGEST:0:19}..."
curl -sL -H "Authorization: Bearer $TOKEN" \
  "https://public.ecr.aws/v2/${REPO}/blobs/${DIGEST}" -o "$TGZ"

# The digest is the content hash, so verifying it also proves the download is intact.
ACTUAL="sha256:$(shasum -a 256 "$TGZ" | cut -d' ' -f1)"
if [[ "$ACTUAL" != "$DIGEST" ]]; then
  echo "Digest mismatch: expected ${DIGEST}, got ${ACTUAL}" >&2
  rm -f "$TGZ"
  exit 1
fi
echo "    digest verified"

helm show chart "$TGZ" | grep -E '^(name|version|appVersion)' | sed 's/^/    /'
echo
echo "==> Install with:"
echo "  helm install --create-namespace -n ack-system ack-elasticache-controller \\"
echo "    ${TGZ} \\"
echo "    --set aws.region=us-west-2 \\"
echo "    --set fullnameOverride=ack-elasticache-controller"
