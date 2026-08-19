#!/usr/bin/env bash
#
# Pre-demo checks. Run against the Control Plane Cluster context with a tenant already
# provisioned. Reports rather than fixes, so it is safe to run minutes before a demo.
#
#   ./verify.sh wi-clienta-uat
#   PROJECT=weblogic-tenants ./verify.sh wi-clienta-uat
set -uo pipefail

TENANT="${1:-wi-clienta-uat}"
PROJECT="${PROJECT:-weblogic-tenants}"
TENANT_NS="${TENANT_NS:-wi}"
# Follows spec.namespacePattern.virtualCluster on the Project. The Platform default is
# loft-<project>-v-<name>; gitops/platform/project.yaml overrides it to p-<project>-v-<name>.
BACKING_NS="${BACKING_NS:-p-${PROJECT}-v-${TENANT}}"
DOMAIN_UID="${DOMAIN_UID:-wi-domain}"

pass=0
fail=0

# Requires non-empty output, not just exit 0. `kubectl get -l <selector>` exits 0 with
# "No resources found" when nothing matches, which silently turned a missing controller
# into a green check.
check() {
  local label="$1"; shift
  if [[ -n "$("$@" 2>/dev/null)" ]]; then
    printf '  \033[32mok\033[0m    %s\n' "$label"
    pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m  %s\n' "$label"
    fail=$((fail + 1))
  fi
}

expect() {
  local label="$1" want="$2"; shift 2
  local got
  got="$("$@" 2>/dev/null)"
  if [[ "$got" == "$want" ]]; then
    printf '  \033[32mok\033[0m    %s\n' "$label"
    pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m  %s (got %q, want %q)\n' "$label" "$got" "$want"
    fail=$((fail + 1))
  fi
}

APP_DOMAIN="${APP_DOMAIN:-apps.example.com}"

expect_field() {
  local label="$1" want="$2" got
  shift 2
  got="$("$@" 2>/dev/null)"
  if [[ "$got" == *"$want"* ]]; then
    printf '  \033[32mok\033[0m    %s\n' "$label"
    pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m  %s (got %q)\n' "$label" "$got"
    fail=$((fail + 1))
  fi
}

# Without a default StorageClass no tenant control plane can start, and the error
# surfaces as an Argo CD integration failure rather than as a storage problem.
DEFAULT_SC="$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{.provisioner}{"\n"}{end}' 2>/dev/null | head -1)"
echo "Storage"
if [[ -n "$DEFAULT_SC" && "$DEFAULT_SC" == *"ebs.csi.aws.com"* ]]; then
  printf '  \033[32mok\033[0m    default StorageClass uses the CSI driver (%s)\n' "${DEFAULT_SC%% *}"
  pass=$((pass + 1))
elif [[ -n "$DEFAULT_SC" ]]; then
  printf '  \033[31mFAIL\033[0m  default StorageClass %s uses %s - the in-tree provisioner was removed in 1.31\n' "${DEFAULT_SC%% *}" "${DEFAULT_SC##* }"
  fail=$((fail + 1))
else
  printf '  \033[31mFAIL\033[0m  no default StorageClass - tenant control planes will sit Pending\n'
  fail=$((fail + 1))
fi
PENDING="$(kubectl get pvc -A --no-headers 2>/dev/null | grep -c Pending || true)"
if [[ "${PENDING:-0}" -gt 0 ]]; then
  printf '  \033[31mFAIL\033[0m  %s PVC(s) Pending\n' "$PENDING"
  fail=$((fail + 1))
else
  printf '  \033[32mok\033[0m    no Pending PVCs\n'
  pass=$((pass + 1))
fi

echo
echo "Platform and ingress"
check "vCluster Platform is running" \
  kubectl -n vcluster-platform get deploy loft
# A Platform installed without loftHost comes up healthy but hands out *.loft.host URLs
# for tenant kubeconfigs, so "the deployment is running" is not sufficient here.
PLATFORM_ENV="$(kubectl -n vcluster-platform get deploy loft \
  -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' 2>/dev/null)"
if [[ "$PLATFORM_ENV" == *"DISABLE_LOFT_ROUTER"* ]]; then
  printf '  \033[32mok\033[0m    Loft Router is disabled (Platform uses its own hostname)\n'
  pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  Loft Router not disabled - Platform will hand out *.loft.host URLs\n'
  fail=$((fail + 1))
fi
if [[ "$PLATFORM_ENV" == *"LICENSE_TOKEN"* ]]; then
  printf '  \033[32mok\033[0m    license token is injected\n'
  pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  no LICENSE_TOKEN on the Platform deployment (Pro features will be unavailable)\n'
  fail=$((fail + 1))
fi

check "Argo CD is running" \
  kubectl -n argocd get deploy argocd-server
check "Argo CD connector secret exists (name must match the template)" \
  kubectl -n vcluster-platform get secret vcluster-argocd
check "cert-manager is running" \
  kubectl -n cert-manager get deploy cert-manager

# cert-manager silently fails to reach Route 53 without injected Pod Identity credentials,
# and every Certificate then sits Pending forever with no obvious cause.
CM_URI="$(kubectl -n cert-manager get pod -l app.kubernetes.io/component=controller \
  -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="AWS_CONTAINER_CREDENTIALS_FULL_URI")].value}' 2>/dev/null)"
if [[ -n "$CM_URI" ]]; then
  printf '  \033[32mok\033[0m    cert-manager has Pod Identity credentials injected\n'
  pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  cert-manager is missing Pod Identity credentials (restart the deployment after creating the association)\n'
  fail=$((fail + 1))
fi

expect_field "wildcard certificate is issued" "True" \
  kubectl -n envoy-gateway-system get certificate apps-wildcard -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# READY=True says nothing about which issuer signed it. A staging cert is Ready and
# browsers reject it, so check the issuer on the actual certificate.
CERT_ISSUER="$(kubectl -n envoy-gateway-system get secret apps-wildcard-tls \
  -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null \
  | openssl x509 -noout -issuer 2>/dev/null)"
if [[ -z "$CERT_ISSUER" ]]; then
  printf '  \033[31mFAIL\033[0m  no TLS secret to inspect\n'
  fail=$((fail + 1))
elif [[ "$CERT_ISSUER" == *STAGING* ]]; then
  printf '  \033[31mFAIL\033[0m  certificate is Let'"'"'s Encrypt STAGING - browsers will reject it\n'
  printf '        set issuerRef to letsencrypt-prod in dns-tls/certificate.yaml, apply, delete the secret\n'
  fail=$((fail + 1))
else
  printf '  \033[32mok\033[0m    certificate signed by a trusted issuer\n'
  pass=$((pass + 1))
fi

expect_field "shared Gateway is programmed" "True" \
  kubectl -n envoy-gateway-system get gateway shared-gw -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}'

NLB="$(kubectl -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=shared-gw \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
printf '  load balancer  %s\n' "${NLB:-<pending>}"
if [[ -n "$NLB" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi

# "It resolves" proves nothing here. A pre-existing *.example.com wildcard already
# answers for *.apps.example.com under RFC 4592 wildcard synthesis, pointing at an
# unrelated us-east-1 ELB. Without our more specific record the demo URL returns someone
# else's app rather than an error, which is far harder to spot live. So compare the
# resolved addresses against the Gateway's own load balancer.
TENANT_IPS="$(dig +short "${TENANT}.${APP_DOMAIN}" A 2>/dev/null | sort -u)"
if [[ -z "$TENANT_IPS" ]]; then
  printf '  \033[31mFAIL\033[0m  DNS does not resolve %s (run dns-tls/route53-record.sh)\n' "${TENANT}.${APP_DOMAIN}"
  fail=$((fail + 1))
elif [[ -z "$NLB" ]]; then
  printf '  \033[31mFAIL\033[0m  %s resolves to %s but there is no load balancer to compare against\n' \
    "${TENANT}.${APP_DOMAIN}" "$(echo $TENANT_IPS | tr '\n' ' ')"
  fail=$((fail + 1))
else
  NLB_IPS="$(dig +short "$NLB" A 2>/dev/null | sort -u)"
  if [[ -n "$NLB_IPS" ]] && comm -12 <(echo "$TENANT_IPS") <(echo "$NLB_IPS") | grep -q .; then
    printf '  \033[32mok\033[0m    %s resolves to the shared Gateway load balancer\n' "${TENANT}.${APP_DOMAIN}"
    pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m  %s resolves to %s, which is NOT the Gateway load balancer (%s)\n' \
      "${TENANT}.${APP_DOMAIN}" "$(echo $TENANT_IPS | tr '\n' ' ')" "$NLB"
    printf '        A wildcard higher in the zone is shadowing it. Run dns-tls/route53-record.sh.\n'
    fail=$((fail + 1))
  fi
fi

echo
echo "Control Plane Cluster"
check "WebLogic operator is running" \
  kubectl -n weblogic-operator-ns get deploy weblogic-operator
# By label, not by name: the chart's Deployment name depends on whether the install
# passed fullnameOverride, but the pod labels are stable either way.
check "ACK ElastiCache controller is running" \
  kubectl -n ack-system get pod -l app.kubernetes.io/name=elasticache-chart -o name
check "ReplicationGroup CRD is installed" \
  kubectl get crd replicationgroups.elasticache.services.k8s.aws

# A running ACK controller is not the same as an authenticated one. The Pod Identity
# agent injects this env var at admission; without it every ReplicationGroup sits
# unreconciled while the deployment looks perfectly healthy.
POD_ID_URI="$(kubectl -n ack-system get pod -l app.kubernetes.io/name=elasticache-chart \
  -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="AWS_CONTAINER_CREDENTIALS_FULL_URI")].value}' 2>/dev/null)"
if [[ -n "$POD_ID_URI" ]]; then
  printf '  \033[32mok\033[0m    ACK controller has EKS Pod Identity credentials injected\n'
  pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  ACK controller is missing Pod Identity credentials (check the association and the eks-pod-identity-agent addon)\n'
  fail=$((fail + 1))
fi
check "shared Envoy Gateway exists" \
  kubectl -n envoy-gateway-system get gateway shared-gw
expect "backing namespace is labelled for the WebLogic operator" "enabled" \
  kubectl get namespace "$BACKING_NS" -o jsonpath='{.metadata.labels.weblogic-operator}'
check "Domain synced up to the backing namespace" \
  kubectl -n "$BACKING_NS" get domain "$DOMAIN_UID"
check "ReplicationGroup synced up to the backing namespace" \
  kubectl -n "$BACKING_NS" get replicationgroup "${DOMAIN_UID}-cache"

echo
echo "ElastiCache reconciliation"
RG_STATE="$(kubectl -n "$BACKING_NS" get replicationgroup "${DOMAIN_UID}-cache" \
  -o jsonpath='{.status.status}' 2>/dev/null)"
RG_ADDR="$(kubectl -n "$BACKING_NS" get replicationgroup "${DOMAIN_UID}-cache" \
  -o jsonpath='{.status.nodeGroups[0].primaryEndpoint.address}' 2>/dev/null)"
printf '  state    %s\n' "${RG_STATE:-<none>}"
printf '  endpoint %s\n' "${RG_ADDR:-<not published yet>}"
if [[ -n "$RG_ADDR" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi

echo
echo "Tenant cluster (${TENANT})"
echo "  connecting..."
if vcluster platform connect vcluster "$TENANT" --project "$PROJECT" >/dev/null 2>&1; then
  check "Domain visible in the tenant" \
    kubectl -n "$TENANT_NS" get domain "$DOMAIN_UID"
  check "operator-created server pods synced back down" \
    kubectl -n "$TENANT_NS" get pods -l weblogic.domainUID="$DOMAIN_UID"
  check "ReplicationGroup visible in the tenant" \
    kubectl -n "$TENANT_NS" get replicationgroup "${DOMAIN_UID}-cache"
  check "cache endpoint publisher is running" \
    kubectl -n "$TENANT_NS" get deploy "${DOMAIN_UID}-cache-publisher"
  CM_ADDR="$(kubectl -n "$TENANT_NS" get configmap "${DOMAIN_UID}-cache-endpoint" \
    -o jsonpath='{.data.endpoint}' 2>/dev/null)"
  printf '  published endpoint %s\n' "${CM_ADDR:-<empty>}"
  if [[ -n "$CM_ADDR" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
  check "HTTPRoute exists in the tenant" \
    kubectl -n "$TENANT_NS" get httproute wi-app
else
  echo "  could not connect to the tenant; skipping tenant-side checks"
  fail=$((fail + 1))
fi

echo
printf 'ok: %d  failed: %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
