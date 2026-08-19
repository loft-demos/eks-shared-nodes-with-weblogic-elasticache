# GitOps-managed Platform objects

Everything the Platform owns — the Project, the templates, the Cluster annotations, and
the tenant instances — is managed by Argo CD rather than applied by hand.

```
gitops/
  bootstrap/   the single Application you apply manually
  platform/    Project, Cluster annotations, VirtualClusterTemplate, ArgoCDApplicationTemplate
  tenants/     one VirtualClusterInstance per client and environment
```

Bootstrap once, after Argo CD and the Platform are both running:

```bash
kubectl apply -f gitops/bootstrap/platform-gitops-app.yaml
```

From then on, adding a tenant is a file in `gitops/tenants/` and nothing else.

## Ordering

A plain recursive directory sync with sync waves, rather than several Applications:

| Wave | Objects | Why |
|---|---|---|
| `-1` | `Project`, `Cluster` | The Project creates the `p-<name>` namespace tenants live in |
| `0` | `VirtualClusterTemplate`, `ArgoCDApplicationTemplate` | Referenced by tenants |
| `1` | `VirtualClusterInstance` | Needs both of the above |

## Two things to know

**These are aggregated API resources, not CRDs.** `management.loft.sh` is served by the
Platform's own API server, and it defaults fields on write. That can leave Argo CD
permanently OutOfSync on fields it never set, which is what the `ignoreDifferences` block
in the bootstrap Application is for. Extend it if you see drift on a field you do not
manage.

**`prune: true` on this Application will delete tenant clusters** if their files are
removed from Git. That is the intent, but it makes a bad merge expensive. Drop `prune`
while iterating if you would rather remove tenants deliberately.

## Not included

The cluster itself, Envoy Gateway, cert-manager, and the Platform and Argo CD Helm
releases stay day-0 `kubectl` and `helm`, since Argo CD needs the Gateway and the Platform
to exist before it can usefully manage anything. They can move into a second Application
once the cluster is bootstrapped.
