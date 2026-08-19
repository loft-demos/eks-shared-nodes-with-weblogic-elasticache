# EKS and Pod Identity

[`examples/eks-cluster.yaml`](../examples/eks-cluster.yaml) builds the cluster and every
IAM association in one pass.

```bash
eksctl create cluster -f examples/eks-cluster.yaml
scripts/bootstrap-aws.sh
```

`bootstrap-aws.sh` creates the ElastiCache subnet group and a security group allowing 6379
from the EKS node security group, then prints the values for the `Cluster` annotations.

## Pod Identity, not IRSA

Three associations, declared in the cluster config so `eksctl` creates the IAM roles and
the associations together:

| Namespace / service account | Policy |
|---|---|
| `ack-system/ack-elasticache-controller` | `AmazonElastiCacheFullAccess`, or the scoped policy in `examples/` |
| `kube-system/aws-load-balancer-controller` | `awsLoadBalancerController` well-known policy |
| `cert-manager/cert-manager` | `certManager` well-known policy |

There is no IRSA annotation on any service account: with Pod Identity the association is
an EKS-side object.

An association names a namespace and service account as **strings**; neither has to exist
when it is created. Helm creates them later and the association starts working then. Keep
`createServiceAccount: false` — each chart creates its own service account, and letting
both create it makes the Helm install fail on ownership metadata.

A pod started before its association existed will not have credentials. Restart the
deployment after adding one.

**Verify injection rather than health.** A controller with no credentials looks perfectly
healthy while nothing reconciles:

```bash
kubectl -n ack-system get pod -l app.kubernetes.io/name=elasticache-chart \
  -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="AWS_CONTAINER_CREDENTIALS_FULL_URI")].value}'
```

Empty output means the association is not matching. Usual causes: the
`eks-pod-identity-agent` addon is missing, or the service account name does not match
exactly.

## Console access for other principals

EKS grants implicit cluster-admin **only to the principal that created the cluster**. AWS
account admin does not carry over: an SSO admin opening the console sees `Unauthorized` on
every Resources panel while the AWS-level views render fine.

`accessConfig.accessEntries` in the cluster config covers this on a rebuild. For an
existing cluster:

```bash
aws eks create-access-entry --cluster-name weblogic-demo \
  --principal-arn "$PRINCIPAL" --type STANDARD

aws eks associate-access-policy --cluster-name weblogic-demo \
  --principal-arn "$PRINCIPAL" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

Two things cost time here:

- **Access policies are not IAM policies.** The ARN is
  `arn:aws:eks::aws:cluster-access-policy/...`. An `arn:aws:iam::aws:policy/...` ARN fails
  with "policyArn parameter format is not valid". `aws eks list-access-policies` prints
  the valid set.
- **SSO role ARNs need their full path.** The path-stripped form the docs imply is
  rejected as an invalid principal. Keep `/aws-reserved/sso.amazonaws.com/<region>/`, where
  that region is where Identity Center is homed, not where the cluster runs.

## Installing the ACK controller

```bash
scripts/fetch-ack-chart.sh
helm install --create-namespace -n ack-system ack-elasticache-controller \
  charts/elasticache-chart-1.7.1.tgz \
  --set aws.region=us-west-2 \
  --set fullnameOverride=ack-elasticache-controller
```

`fetch-ack-chart.sh` pulls the chart through ECR Public's anonymous token flow and verifies
it against the manifest digest. `helm registry login` also works, but fails on macOS when
the keychain already holds a `public.ecr.aws` entry owned by another application: the login
reports `-25299`, Helm reuses a stale token, and the pull fails with a misleading
"Authorization Token is invalid".

`fullnameOverride` is not cosmetic. Without it the Deployment is named
`ack-elasticache-controller-elasticache-chart`, and every `deploy/ack-elasticache-controller`
command returns NotFound. The service account keeps its own name either way, which is what
the association binds to.
