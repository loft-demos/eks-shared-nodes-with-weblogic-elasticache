# API-driven tenant creation

A business system — a CRM, an onboarding workflow, a service catalogue — needs to cause a
tenant cluster to exist. There are three surfaces, and they are not alternatives so much as
different places to draw the line.

## The three surfaces

| Surface | What the caller does | Good when |
|---|---|---|
| **REST** | One authenticated `POST` of a `VirtualClusterInstance` | The calling system can already make an HTTP callout |
| **Go client** | Typed clientset from `github.com/loft-sh/api/v4` | You are writing a service anyway and want compile-time types |
| **GitOps** | Commit a file; Argo CD reconciles | Provisioning must be reviewable and auditable |

All three create the same object. The Platform does not care which produced it.

## REST

The Platform management API is a Kubernetes API server serving `management.loft.sh`,
reachable at `https://<loftHost>/kubernetes/management`. Authentication is a Platform
access key as a bearer token.

```bash
curl -X POST \
  "https://$LOFT_DOMAIN/kubernetes/management/apis/management.loft.sh/v1/namespaces/p-weblogic-tenants/virtualclusterinstances" \
  -H "Authorization: Bearer $ACCESS_KEY" \
  -H 'Content-Type: application/json' \
  -d '{
        "apiVersion": "management.loft.sh/v1",
        "kind": "VirtualClusterInstance",
        "metadata": {"name": "acme-corp-uat", "namespace": "p-weblogic-tenants"},
        "spec": {
          "clusterRef": {"cluster": "loft-cluster"},
          "templateRef": {"name": "weblogic-shared-node"},
          "parameters": "cacheMode: in-tenant\nmanagedServerCount: 3"
        }
      }'
```

[`scripts/create-tenant-via-api.sh`](../scripts/create-tenant-via-api.sh) wraps that and
polls until the tenant reports `Ready`.

Two details that cost time:

- **`spec.parameters` is a YAML string, not an object.** It carries the template's
  parameter values as a block of YAML inside a JSON string field.
- **The project namespace prefix comes from Platform Config.** `p-` is the default, giving
  `p-<project>`; some installations use a different prefix.

An access key inherits the permissions of the user that created it. Create a dedicated
user scoped to the project rather than issuing an admin key to an integration.

## Go client

`github.com/loft-sh/api/v4` is a public module with a generated typed clientset. Match its
major/minor to the Platform you are calling — `v4.11.2` against Platform 4.11.2.

```go
import (
    managementv1 "github.com/loft-sh/api/v4/pkg/apis/management/v1"
    "github.com/loft-sh/api/v4/pkg/clientset/versioned"
)

client, _ := versioned.NewForConfig(restConfig)   // bearer token = access key

_, err := client.ManagementV1().
    VirtualClusterInstances("p-weblogic-tenants").
    Create(ctx, &managementv1.VirtualClusterInstance{ /* ... */ }, metav1.CreateOptions{})
```

The interface is ordinary client-go: `Create`, `Get`, `List`, `Update`, `Delete`,
`DeleteCollection`, and watches. If you already run Go services, this is less code than
hand-rolling HTTP, and the types move with the Platform version.

## GitOps

[`gitops/`](../gitops/) covers this: a file under `gitops/tenants/` and Argo CD does the
rest. See [04](04-platform-and-gitops.md).

## Which one

For a demo, **show REST**. A single `curl` creating a real cluster makes the point in a way
a Git commit does not, and it maps directly onto an outbound webhook from whatever system
the audience actually runs.

For production, the honest recommendation is usually **both**: the business system calls a
small service, and that service commits to Git rather than calling the Platform directly.
The caller still gets an API. You still get review, history, and a single reconciled source
of truth — which matters if provisioning a tenant is a change a regulated organisation has
to evidence later.

Going straight from the business system to the Platform API is faster and has fewer moving
parts, at the cost of the audit trail living in Platform audit logs and the calling system
rather than in Git. `config.audit` is worth turning on if you take this path.

The middle option is a Git-writing service, which is more code than either.

## Do not point Argo CD at the management API

The Platform management API serves **only** `management.loft.sh`. It has no pods, no
namespaces, and the vCluster docs call out Argo CD specifically as a tool that does not
cope with that.

Point Argo CD at the **cluster** API server instead — `https://kubernetes.default.svc` for
an in-cluster Argo CD. The `management.loft.sh` resources are available there too through
API aggregation, alongside everything else Argo CD expects to find. That is what
[`gitops/bootstrap/platform-gitops-app.yaml`](../gitops/bootstrap/platform-gitops-app.yaml)
does.
