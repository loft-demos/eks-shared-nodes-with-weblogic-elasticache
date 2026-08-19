# WebLogic and ACK ElastiCache on vCluster shared-node tenant clusters

Run Oracle WebLogic domains across many tenant clusters from a single operator, and let
each tenant provision its own AWS ElastiCache through ACK, without any tenant holding an
AWS credential.

```
                  Control Plane Cluster (EKS)
 ┌──────────────────────────────────────────────────────────────┐
 │ WebLogic Operator (one, LabelSelector-scoped)                 │
 │ ACK ElastiCache Controller (one, EKS Pod Identity) ───────────┼──▶ AWS
 │ Envoy Gateway + NLB  •  cert-manager  •  vCluster Platform    │
 │                                                               │
 │ ns: p-<project>-v-<tenant>                                   │
 │  ├─ Domain            (synced up)   ─▶ operator creates pods  │
 │  ├─ ReplicationGroup  (synced up)   ─▶ ACK reconciles to AWS  │
 │  └─ HTTPRoute         (synced up)   ─▶ shared Gateway         │
 └───────────────▲──────────────────────────────────────────────┘
                 │ CRs up  /  pods, services, status back down
        ┌────────┴─────────┐
        │ Tenant: client A │
        └──────────────────┘
```

A developer applies a `Domain` in their own cluster. vCluster syncs it up, the shared
operator reconciles it and creates the server pods, and those pods sync back down so the
developer sees them where they expect. The same round trip carries an ACK
`ReplicationGroup` out to AWS and its endpoint back.

## Contents

| Path | What it is |
|---|---|
| [`docs/01-crd-sync.md`](docs/01-crd-sync.md) | Syncing the WebLogic and ACK CRDs, and the reference patches that make them resolve |
| [`docs/02-cache-backends.md`](docs/02-cache-backends.md) | ElastiCache via ACK vs in-tenant Redis, behind one application contract |
| [`docs/03-eks-and-pod-identity.md`](docs/03-eks-and-pod-identity.md) | Cluster build, Pod Identity for the controllers, console access entries |
| [`docs/04-platform-and-gitops.md`](docs/04-platform-and-gitops.md) | Platform install, `loftHost`, Argo CD connector and its RBAC |
| [`docs/05-tls-dns-ingress.md`](docs/05-tls-dns-ingress.md) | cert-manager DNS01, wildcard cert, Envoy Gateway |
| [`docs/06-api-driven-tenant-creation.md`](docs/06-api-driven-tenant-creation.md) | Creating tenants from REST, the Go client, or Git |
| [`gitops/`](gitops/) | Platform objects and tenants, managed by Argo CD |
| `examples/` | Day-0 manifests and Helm values referenced by the docs, including the default StorageClass |
| `charts/weblogic-domain/` | The tenant-side Helm chart |
| `app/` | Demo servlet, WDT model, auxiliary image build |
| `scripts/` | Bootstrap, chart fetch, DNS, connector, pre-demo verifier |

## Four things that are not obvious

**Name references inside a synced CR do not resolve by themselves.** A `Domain` points at
its credentials secret, runtime encryption secret, `Cluster`, and mounted `ConfigMap` by
name. Those names are translated on the way up, and the operator looks for the
untranslated ones. `patches` with `reference` entries rewrite each.
→ [01](docs/01-crd-sync.md#reference-patches)

**`configMaps.all: true` is required.** vCluster syncs only ConfigMaps it sees a tenant pod
reference. The WebLogic pods are created on the Control Plane Cluster by the operator, so
that detection never fires. → [01](docs/01-crd-sync.md#configmaps)

**Pods created by a host-side operator use host DNS** and cannot resolve tenant Service
names. The in-tenant cache works because vCluster recreates the tenant Service with the
host Service's ClusterIP, so publishing the IP works where the name does not.
→ [02](docs/02-cache-backends.md#reaching-an-in-tenant-cache)

**EKS gives you an EBS CSI driver but no StorageClass**, and the `gp2` class it ships uses
a provisioner removed in Kubernetes 1.31. Tenant control planes need a PVC for embedded
etcd, so with no default class no tenant starts — and it surfaces as an Argo CD 504, not a
storage error. → [03](docs/03-eks-and-pod-identity.md#a-default-storageclass-is-required)

**A managed cache takes minutes.** `cacheMode: in-tenant` gives a tenant a working Redis in
seconds with no AWS, against the identical application — which makes creating a tenant
live viable. → [02](docs/02-cache-backends.md)

## Versions

Verified together on a live EKS cluster.

| Component | Version | Note |
|---|---|---|
| Kubernetes (EKS) | 1.36 | Tenant clusters pinned to the same minor |
| vCluster | 0.36.0 | Host 1.36 + tenant 1.36 is *tested* upstream |
| vCluster Platform | 4.11.2 | Pro license: CRD sync and Sleep Mode are both Pro |
| WebLogic Operator | 4.3.14 | `Domain` v9, `Cluster` v1 |
| WebLogic Server | 14.1.2.0 | Sample WAR uses `javax.servlet.*` |
| ACK ElastiCache | 1.7.1 | |
| Envoy Gateway | 1.7.2 | |
| cert-manager | 1.21.1 | Route 53 DNS01 via Pod Identity |
| Argo CD | 3.5.1 (chart 10.4.0) | |
| eksctl | 0.190+ | Needs `iam.podIdentityAssociations` |

Booting a WebLogic domain needs Oracle Container Registry credentials, which this repo
does not include.

## References

**vCluster** — [custom resource sync](https://www.vcluster.com/docs/vcluster/configure/vcluster-yaml/sync/to-host/advanced/custom-resources) ·
[patching](https://www.vcluster.com/docs/vcluster/configure/vcluster-yaml/sync/patching) ·
[version compatibility](https://www.vcluster.com/docs/vcluster/manage/upgrade/supported_versions) ·
[auto sleep](https://www.vcluster.com/docs/vcluster/configure/vcluster-yaml/sleep)

**Platform** — [Argo CD connector](https://www.vcluster.com/docs/platform/integrations/argocd/connect-argocd) ·
[deploy applications](https://www.vcluster.com/docs/platform/integrations/argocd/deploy-applications) ·
[platform configs](https://www.vcluster.com/docs/platform/configure/platform-configs/overview) ·
[Akuity for private clusters](https://www.vcluster.com/docs/platform/integrations/argocd/connect-akuity)

**AWS** — [ACK ReplicationGroup](https://aws-controllers-k8s.github.io/community/reference/elasticache/v1alpha1/replicationgroup/) ·
[EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/APIReference/API_CreatePodIdentityAssociation.html) ·
[eksctl pod identity](https://docs.aws.amazon.com/eks/latest/eksctl/pod-identity-associations.html) ·
[cert-manager Route53](https://cert-manager.io/docs/configuration/acme/dns01/route53/)

**WebLogic** — [Domain schema](https://github.com/oracle/weblogic-kubernetes-operator/blob/main/documentation/domains/Domain.md) ·
[WebLogic Deploy Tooling](https://github.com/oracle/weblogic-deploy-tooling)
