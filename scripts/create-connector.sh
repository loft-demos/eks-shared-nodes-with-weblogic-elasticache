#!/usr/bin/env bash
#
# Generates an Argo CD API token for the vcluster-platform account and creates the
# Platform connector Secret from it.
#
# Uses the Argo CD REST API over a port-forward rather than the argocd CLI, so there is
# nothing extra to install. The token is never echoed.
#
# Run after Argo CD is installed with argocd-values.yaml.
#
#   ./argocd/create-connector.sh
set -euo pipefail

ARGOCD_NS="${ARGOCD_NS:-argocd}"
PLATFORM_NS="${PLATFORM_NS:-vcluster-platform}"
ACCOUNT="${ACCOUNT:-vcluster-platform}"
# Must match integrations.argoCD.connector in the tenant template.
CONNECTOR_NAME="${CONNECTOR_NAME:-vcluster-argocd}"
PORT="${PORT:-18080}"

cleanup() { [[ -n "${PF_PID:-}" ]] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

echo "==> Checking Argo CD is up"
kubectl -n "$ARGOCD_NS" rollout status deploy/argocd-server --timeout=120s

echo "==> Confirming the ${ACCOUNT} account exists"
# A missing account here almost always means Argo CD was installed without
# argocd-values.yaml, or the ConfigMap was patched without restarting argocd-server.
if ! kubectl -n "$ARGOCD_NS" get cm argocd-cm -o jsonpath="{.data['accounts\.${ACCOUNT}']}" 2>/dev/null | grep -q apiKey; then
  echo "Account '${ACCOUNT}' is not configured with apiKey in argocd-cm." >&2
  echo "Reinstall with --values argocd/argocd-values.yaml, or patch argocd-cm and restart:" >&2
  echo "  kubectl -n ${ARGOCD_NS} rollout restart deploy/argocd-server" >&2
  exit 1
fi

# Port 80, not 443: argocd-values.yaml runs the server with server.insecure=true so the
# shared Envoy Gateway can terminate TLS. Talking https to it would fail the handshake.
echo "==> Port-forwarding argocd-server on :${PORT}"
kubectl -n "$ARGOCD_NS" port-forward svc/argocd-server "${PORT}:80" >/dev/null 2>&1 &
PF_PID=$!
for _ in $(seq 1 30); do
  curl -s "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1 && break
  sleep 1
done

echo "==> Authenticating as admin"
ADMIN_PW="$(kubectl -n "$ARGOCD_NS" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"
if [[ -z "$ADMIN_PW" ]]; then
  echo "argocd-initial-admin-secret not found. If the admin password was already rotated," >&2
  echo "set ADMIN_PW in the environment and re-run." >&2
  exit 1
fi

SESSION_JSON="$(curl -s -X POST "http://127.0.0.1:${PORT}/api/v1/session" \
  -H 'Content-Type: application/json' \
  -d "$(ADMIN_PW="$ADMIN_PW" python3 -c 'import json,os;print(json.dumps({"username":"admin","password":os.environ["ADMIN_PW"]}))')")"
JWT="$(printf '%s' "$SESSION_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("token",""))')"
if [[ -z "$JWT" ]]; then
  echo "Admin login failed: $SESSION_JSON" >&2
  exit 1
fi

echo "==> Generating an API token for ${ACCOUNT}"
TOKEN_JSON="$(curl -s -X POST "http://127.0.0.1:${PORT}/api/v1/account/${ACCOUNT}/token" \
  -H "Authorization: Bearer ${JWT}" -H 'Content-Type: application/json' -d '{}')"
API_TOKEN="$(printf '%s' "$TOKEN_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("token",""))')"
if [[ -z "$API_TOKEN" ]]; then
  echo "Token generation failed: $TOKEN_JSON" >&2
  exit 1
fi

echo "==> Creating the ${CONNECTOR_NAME} connector Secret in ${PLATFORM_NS}"
# Name must match the template's integrations.argoCD.connector value or tenants come up
# without their app stack.
#
# http:// because server.insecure=true means argocd-server speaks plain HTTP in-cluster.
# Pointing at the public https://argocd.example.com would also work and would
# get a real certificate, but it hairpins Platform -> NLB -> Envoy -> Argo CD for traffic
# that never needs to leave the cluster.
kubectl -n "$PLATFORM_NS" create secret generic "$CONNECTOR_NAME" \
  --from-literal=server="http://argocd-server.${ARGOCD_NS}.svc.cluster.local" \
  --from-literal=token="$API_TOKEN" \
  --from-literal=namespace="$ARGOCD_NS" \
  --from-literal=insecure="true" \
  --dry-run=client -o yaml \
  | kubectl label --local -f - loft.sh/connector-type=argocd -o yaml \
  | kubectl apply -f -

cat <<SUMMARY

==> Done. Verify with:

  kubectl -n ${PLATFORM_NS} get secret ${CONNECTOR_NAME} \\
    -o jsonpath='{.metadata.labels}{"\\n"}'
  kubectl -n ${PLATFORM_NS} logs deploy/loft | grep -i argocd | tail -5

The connector should appear under Infrastructure > Connectors in the Platform UI.

SUMMARY
