#!/usr/bin/env bash
#
# Creates the AWS side of the ElastiCache story that the tenant chart does not own:
# a cache subnet group in the EKS VPC's private subnets, and a security group that lets
# the EKS nodes reach Redis on 6379.
#
# Tenants create only the ReplicationGroup. Subnets and security groups stay with the
# platform team, which is the guardrail half of "let app teams self-serve AWS resources".
#
# Idempotent: safe to re-run.
#
#   ./bootstrap-aws.sh
#   CLUSTER_NAME=weblogic-demo AWS_REGION=us-west-2 ./bootstrap-aws.sh
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-weblogic-demo}"
AWS_REGION="${AWS_REGION:-us-west-2}"
CACHE_SUBNET_GROUP="${CACHE_SUBNET_GROUP:-weblogic-demo-cache-subnets}"
CACHE_SECURITY_GROUP="${CACHE_SECURITY_GROUP:-weblogic-demo-cache-sg}"
REDIS_PORT="${REDIS_PORT:-6379}"

aws() { command aws --region "$AWS_REGION" "$@"; }

echo "==> Preflight"
for tool in aws python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Required tool not found: ${tool}" >&2
    exit 1
  fi
done

# Fail here with something readable rather than on an opaque describe-cluster error.
if ! CALLER="$(aws sts get-caller-identity --query 'Arn' --output text 2>&1 | tr -s '[:space:]' ' ')"; then
  echo "Not authenticated to AWS in ${AWS_REGION}: ${CALLER}" >&2
  echo "Set AWS_PROFILE / AWS_REGION. If the identity's policy requires MFA, export session" >&2
  echo "credentials from 'aws sts get-session-token --serial-number ... --token-code ...' first." >&2
  exit 1
fi
echo "    identity=${CALLER}"
echo "    region=${AWS_REGION}"

if ! aws eks describe-cluster --name "$CLUSTER_NAME" >/dev/null 2>&1; then
  echo "EKS cluster ${CLUSTER_NAME} not found in ${AWS_REGION}." >&2
  echo "Create it first (eksctl create cluster -f eks-cluster.yaml), or set CLUSTER_NAME/AWS_REGION." >&2
  echo "A region mismatch between this shell and eks-cluster.yaml is the usual cause." >&2
  exit 1
fi

echo "==> Reading VPC and cluster security group from EKS cluster ${CLUSTER_NAME}"
CLUSTER_JSON="$(aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.resourcesVpcConfig' --output json)"
VPC_ID="$(printf '%s' "$CLUSTER_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["vpcId"])')"
CLUSTER_SG="$(printf '%s' "$CLUSTER_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["clusterSecurityGroupId"])')"
echo "    vpc=${VPC_ID} clusterSecurityGroup=${CLUSTER_SG}"

echo "==> Finding private subnets in ${VPC_ID}"
# eksctl tags the private subnets it creates; fall back to any subnet without a public IP
# mapping if this VPC was not built by eksctl.
PRIVATE_SUBNETS="$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=*Private*" \
  --query 'Subnets[].SubnetId' --output text)"
if [[ -z "$PRIVATE_SUBNETS" ]]; then
  PRIVATE_SUBNETS="$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=map-public-ip-on-launch,Values=false" \
    --query 'Subnets[].SubnetId' --output text)"
fi
if [[ -z "$PRIVATE_SUBNETS" ]]; then
  echo "No private subnets found in ${VPC_ID}. Set them manually and re-run." >&2
  exit 1
fi
echo "    subnets=${PRIVATE_SUBNETS}"

echo "==> Ensuring cache subnet group ${CACHE_SUBNET_GROUP}"
if aws elasticache describe-cache-subnet-groups \
     --cache-subnet-group-name "$CACHE_SUBNET_GROUP" >/dev/null 2>&1; then
  echo "    already exists"
else
  # shellcheck disable=SC2086
  aws elasticache create-cache-subnet-group \
    --cache-subnet-group-name "$CACHE_SUBNET_GROUP" \
    --cache-subnet-group-description "Example Corp vCluster demo tenant caches" \
    --subnet-ids $PRIVATE_SUBNETS >/dev/null
  echo "    created"
fi

echo "==> Ensuring security group ${CACHE_SECURITY_GROUP}"
CACHE_SG="$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${CACHE_SECURITY_GROUP}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
if [[ -z "$CACHE_SG" || "$CACHE_SG" == "None" ]]; then
  CACHE_SG="$(aws ec2 create-security-group \
    --group-name "$CACHE_SECURITY_GROUP" \
    --description "Demo tenant ElastiCache access" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text)"
  echo "    created ${CACHE_SG}"
else
  echo "    already exists ${CACHE_SG}"
fi

echo "==> Ensuring ingress ${REDIS_PORT} from ${CLUSTER_SG}"
# With the Amazon VPC CNI, pods get VPC addresses and use the node's security groups, so
# allowing the EKS cluster security group covers the WebLogic server pods.
if aws ec2 authorize-security-group-ingress \
     --group-id "$CACHE_SG" \
     --protocol tcp --port "$REDIS_PORT" \
     --source-group "$CLUSTER_SG" >/dev/null 2>&1; then
  echo "    rule added"
else
  echo "    rule already present"
fi

cat <<SUMMARY

==> Done.

Add these to the vCluster Platform Cluster resource (see platform/cluster-annotations.yaml):

  demos.vcluster.com/eks-cluster-name:       ${CLUSTER_NAME}
  demos.vcluster.com/aws-region:             ${AWS_REGION}
  demos.vcluster.com/cache-subnet-group:     ${CACHE_SUBNET_GROUP}
  demos.vcluster.com/cache-security-group:   ${CACHE_SG}

SUMMARY
