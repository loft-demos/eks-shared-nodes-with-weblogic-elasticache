# CRD sync

One WebLogic operator and one ACK ElastiCache controller serve every tenant. Tenants
create the custom resources; the controllers on the Control Plane Cluster reconcile them.

Full template: [`gitops/platform/virtualclustertemplate-weblogic.yaml`](../gitops/platform/virtualclustertemplate-weblogic.yaml)

```yaml
sync:
  toHost:
    customResources:
      domains.weblogic.oracle:
        enabled: true
        patches: [...]          # see below
      clusters.weblogic.oracle:
        enabled: true
      replicationgroups.elasticache.services.k8s.aws:
        enabled: true
    secrets:
      enabled: true
      all: true
    configMaps:
      enabled: true
      all: true
```

The CRD must exist on the Control Plane Cluster **before** a tenant starts. vCluster
registers custom-resource syncers during startup, so a tenant created against a missing
CRD fails before its workloads come up. vCluster then copies the CRD down into each
tenant, so tenants can create the resource without hosting a controller.

## Reference patches {#reference-patches}

A `Domain` refers to other objects by name. Those names are translated when the object is
synced up, so the operator would look for names that do not exist. Each reference needs a
patch:

```yaml
patches:
  - path: spec.clusters[*]
    reference: { apiVersion: weblogic.oracle/v1, kind: Cluster, namePath: name }
  - path: spec.webLogicCredentialsSecret
    reference: { apiVersion: v1, kind: Secret, namePath: name }
  - path: spec.configuration.model.runtimeEncryptionSecret
    reference: { apiVersion: v1, kind: Secret }
  - path: spec.serverPod.volumes[*].configMap
    reference: { apiVersion: v1, kind: ConfigMap, namePath: name }
```

`path` points at the object holding the name; `namePath` is the field within it. `[*]`
applies to each element and is skipped where the path is absent, so a volume that is not a
ConfigMap is left alone.

Test these first against your operator version. They are the most likely thing to need
adjustment, and the failure mode is server pods that never start with an error that points
at a missing secret rather than at sync.

## configMaps.all {#configmaps}

`sync.toHost.configMaps` defaults to syncing only ConfigMaps that vCluster can see a
tenant pod referencing. The WebLogic server pods are created on the Control Plane Cluster
by the operator, not synced up from the tenant, so that detection never fires and the
cache endpoint ConfigMap is never synced. `all: true` is required. The same reasoning
applies to `secrets`, which the operator reads directly from the backing namespace.

## Namespace adoption

Install the operator with a label selector rather than a namespace list, so it picks up
each new tenant automatically:

```bash
--set domainNamespaceSelectionStrategy=LabelSelector \
--set domainNamespaceLabelSelector=weblogic-operator=enabled \
--set enableClusterRoleBinding=true
```

The template stamps the matching label on every tenant's backing namespace:

```yaml
spaceTemplate:
  metadata:
    labels:
      weblogic-operator: enabled
```

`enableClusterRoleBinding=true` lets the operator manage namespaces that appear after it
was installed, which is exactly what happens as tenants come and go.

Backing namespaces follow the Project's `spec.namespacePattern.virtualCluster`. The
Platform default is `loft-<project>-v-<name>`; the example Project overrides it to
`p-<project>-v-<name>`. Whichever you use, the operator finds them by label rather than by
name, so the pattern only matters for the commands you type.

The ACK controller needs none of this: its `installScope` defaults to cluster-wide, so it
already watches every namespace.

## Status flows back

Custom resource sync treats status as host-owned and syncs it back down. A tenant reading
its own `ReplicationGroup` sees the endpoint ACK wrote on the Control Plane Cluster copy.
[Cache backends](02-cache-backends.md) builds on this.
