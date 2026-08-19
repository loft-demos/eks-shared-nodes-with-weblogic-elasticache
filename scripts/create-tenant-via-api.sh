#!/usr/bin/env bash
#
# Creates a tenant cluster with a single authenticated HTTP call.
#
# This is the shape a business system would use: an outbound webhook or callout POSTs a
# VirtualClusterInstance and the Platform does the rest. Nothing here is vCluster-specific
# tooling - it is one POST with a bearer token.
#
#   export LOFT_DOMAIN=platform.example.com
#   export ACCESS_KEY=...            # Platform > User > Access Keys
#   ./scripts/create-tenant-via-api.sh acme-corp-uat
#
# The access key inherits the permissions of the user that created it, so scope that user
# to the project rather than using an admin key for an integration.
set -euo pipefail

TENANT="${1:?usage: $0 <tenant-name> [cache-mode]}"
CACHE_MODE="${2:-in-tenant}"
LOFT_DOMAIN="${LOFT_DOMAIN:?set LOFT_DOMAIN, e.g. platform.example.com}"
ACCESS_KEY="${ACCESS_KEY:?set ACCESS_KEY from Platform > User > Access Keys}"
PROJECT="${PROJECT:-weblogic-tenants}"
# Project namespace prefix comes from Platform Config; p- is the default.
PROJECT_NS="${PROJECT_NS:-p-${PROJECT}}"
TEMPLATE="${TEMPLATE:-weblogic-shared-node}"

API="https://${LOFT_DOMAIN}/kubernetes/management/apis/management.loft.sh/v1"

echo "==> POST ${TENANT} to ${PROJECT}"
BODY="$(python3 -c '
import json, os, sys
tenant, project_ns, template, mode = sys.argv[1:5]
print(json.dumps({
    "apiVersion": "management.loft.sh/v1",
    "kind": "VirtualClusterInstance",
    "metadata": {"name": tenant, "namespace": project_ns},
    "spec": {
        "clusterRef": {"cluster": os.environ.get("CLUSTER", "loft-cluster")},
        "displayName": tenant,
        # Required. The Argo CD integration mints a scoped access key per tenant and takes
        # its owner from here; without it the tenant fails to reconcile with
        # "access key has no valid owner". The UI sets this implicitly, the API does not.
        "owner": {"user": os.environ.get("OWNER_USER", "admin")},
        "templateRef": {"name": template},
        # parameters is a YAML *string*, not an object.
        "parameters": "\n".join([
            f"cacheMode: {mode}",
            "managedServerCount: 3",
            "sleepAfterInactivity: 2h",
        ]),
    },
}))' "$TENANT" "$PROJECT_NS" "$TEMPLATE" "$CACHE_MODE")"

RESPONSE="$(curl -sS -w '\n%{http_code}' \
  -X POST "${API}/namespaces/${PROJECT_NS}/virtualclusterinstances" \
  -H "Authorization: Bearer ${ACCESS_KEY}" \
  -H 'Content-Type: application/json' \
  -d "$BODY")"

CODE="$(printf '%s' "$RESPONSE" | tail -1)"
PAYLOAD="$(printf '%s' "$RESPONSE" | sed '$d')"

if [[ "$CODE" != "201" && "$CODE" != "200" ]]; then
  echo "Create failed (HTTP ${CODE}):" >&2
  printf '%s\n' "$PAYLOAD" | python3 -c 'import json,sys
try: print("  " + json.load(sys.stdin).get("message","")) 
except Exception: print("  " + sys.stdin.read()[:400])' >&2
  exit 1
fi
echo "    created"

echo "==> Waiting for the tenant to report ready"
for _ in $(seq 1 60); do
  PHASE="$(curl -sS "${API}/namespaces/${PROJECT_NS}/virtualclusterinstances/${TENANT}" \
    -H "Authorization: Bearer ${ACCESS_KEY}" \
    | python3 -c 'import json,sys; print((json.load(sys.stdin).get("status") or {}).get("phase",""))' 2>/dev/null || true)"
  printf '\r    phase: %-14s' "${PHASE:-unknown}"
  [[ "$PHASE" == "Ready" ]] && { echo; break; }
  sleep 5
done

cat <<SUMMARY

==> Connect with:

  vcluster platform connect vcluster ${TENANT} --project ${PROJECT}

Delete the same way it was created:

  curl -sS -X DELETE "${API}/namespaces/${PROJECT_NS}/virtualclusterinstances/${TENANT}" \\
    -H "Authorization: Bearer \$ACCESS_KEY"

SUMMARY
