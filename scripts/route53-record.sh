#!/usr/bin/env bash
#
# Creates the wildcard alias A record pointing *.apps.example.com at the NLB that
# fronts the shared Envoy Gateway.
#
# One wildcard record covers every tenant, so adding a tenant needs no DNS work. An alias
# record rather than a CNAME because the name is a wildcard at a zone apex-adjacent level
# and aliases are free to resolve; it also tracks the NLB if its addresses change.
#
# Idempotent: UPSERT, so re-running after an NLB rebuild just repoints it.
#
#   ./route53-record.sh
#   APP_DOMAIN=apps.example.com ./route53-record.sh
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-west-2}"
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-Z0123456789ABCDEFGHIJ}"
APP_DOMAIN="${APP_DOMAIN:-apps.example.com}"
GATEWAY_NS="${GATEWAY_NS:-envoy-gateway-system}"
GATEWAY_NAME="${GATEWAY_NAME:-shared-gw}"

echo "==> Finding the Envoy Gateway load balancer"
# By label: the Envoy service name carries a per-Gateway hash.
NLB_DNS="$(kubectl -n "$GATEWAY_NS" get svc \
  -l "gateway.envoyproxy.io/owning-gateway-name=${GATEWAY_NAME}" \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"

if [[ -z "$NLB_DNS" ]]; then
  echo "No load balancer hostname on the Envoy service yet." >&2
  echo "The AWS Load Balancer Controller may still be provisioning it. Check:" >&2
  echo "  kubectl -n ${GATEWAY_NS} get svc -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY_NAME}" >&2
  echo "  kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=30" >&2
  exit 1
fi
echo "    nlb=${NLB_DNS}"

# An alias record needs the load balancer's canonical hosted zone, which is a property of
# the load balancer itself and differs per region and per LB type.
NLB_ZONE="$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
  --query "LoadBalancers[?DNSName=='${NLB_DNS}'].CanonicalHostedZoneId | [0]" --output text)"
if [[ -z "$NLB_ZONE" || "$NLB_ZONE" == "None" ]]; then
  echo "Could not resolve the canonical hosted zone for ${NLB_DNS}." >&2
  echo "If this is a Classic LB, the EnvoyProxy annotations did not take effect." >&2
  exit 1
fi
echo "    nlbZone=${NLB_ZONE}"

echo "==> Upserting *.${APP_DOMAIN} -> ${NLB_DNS}"
CHANGE_ID="$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "$(cat <<JSON
{
  "Comment": "Wildcard for tenant HTTPRoutes",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "*.${APP_DOMAIN}",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "${NLB_ZONE}",
          "DNSName": "dualstack.${NLB_DNS}",
          "EvaluateTargetHealth": true
        }
      }
    }
  ]
}
JSON
)" --query 'ChangeInfo.Id' --output text)"

echo "    change=${CHANGE_ID}, waiting for propagation"
aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"

cat <<SUMMARY

==> Done. Verify with:

  dig +short wi-clienta-uat.${APP_DOMAIN}
  curl -sSI https://wi-clienta-uat.${APP_DOMAIN}/demo/ | head -1

If the certificate is still the Let's Encrypt staging one, curl needs -k until you switch
the Certificate's issuerRef to letsencrypt-prod.

SUMMARY
