# Platform and GitOps

## vCluster Platform

Install with [`examples/vcluster-platform-values.yaml`](../examples/vcluster-platform-values.yaml):

```bash
helm upgrade vcluster-platform vcluster-platform --install \
  --repo https://charts.loft.sh/ \
  --namespace vcluster-platform --create-namespace \
  --version 4.11.2 \
  --values examples/vcluster-platform-values.yaml \
  --set env.LICENSE_TOKEN="$TOKEN" \
  --set admin.password="$ADMIN_PASSWORD"
```

**Set `config.loftHost`.** Left unset, the Platform provisions a hosted `*.loft.host`
domain through the Loft Router and generates every URL it hands out — tenant kubeconfig
endpoints, OIDC redirects, invitation links — against that domain instead of yours.
`env.DISABLE_LOFT_ROUTER: "true"` makes the intent unambiguous.

Only `config.audit` is a real chart value. The rest of `config` is passed through verbatim
to the Platform's own config object and lands base64-encoded in a Secret, so `helm
template` will not catch a typo in `loftHost`, `costControl`, or `uiSettings`. Check them
against the platform config reference.

That config object is shared with the UI editor, so a setting changed in the UI is
overwritten by the next `helm upgrade` that carries a `config` block. Pick one as the
source of truth.

`LICENSE_TOKEN` applies the license at startup with no click-through. Pro is required:
custom resource sync and Sleep Mode both need it.

The UI is exposed through the shared Gateway rather than the chart's Ingress
([`examples/vcp-httproute.yaml`](../examples/vcp-httproute.yaml)), so it uses the same
wildcard certificate as everything else. Leave `ingress.enabled: false` or you get two
competing paths to the same Service.

## Argo CD

Install with [`examples/argocd-values.yaml`](../examples/argocd-values.yaml), which
declares the Platform's account and RBAC as chart values:

```yaml
configs:
  cm:
    accounts.vcluster-platform: apiKey    # tokens yes, UI login no
  params:
    server.insecure: true                 # Envoy terminates TLS
  rbac:
    policy.default: ""
    policy.csv: |
      p, role:vcluster-platform, clusters, get|create|update|delete, *, allow
      p, role:vcluster-platform, applications, get|create|update|delete|sync, */*, allow
      g, vcluster-platform, role:vcluster-platform
```

(one line per verb in the real file)

An account patched into `argocd-cm` after install is only picked up when `argocd-server`
restarts; declaring it as a chart value avoids a confusing "account not found" at token
time.

**`sync` is the permission people omit.** Without it, deleting a tenant that has installed
apps hangs on an in-progress sync the Platform cannot cancel.

`server.insecure: true` is what lets an HTTPRoute work. Argo CD otherwise serves HTTPS and
301-redirects every HTTP request, so a plain-HTTP route produces a redirect loop. The cost
is an unencrypted hop from Envoy to Argo CD inside the cluster.

Set `global.domain` too — it derives `configs.cm.url`, and left alone the chart's
`argocd.example.com` default becomes the base for every absolute URL Argo CD generates.

Then mint the token and write the connector:

```bash
scripts/create-connector.sh
```

The Secret must be named exactly what the tenant template's
`integrations.argoCD.connector` references. A mismatch gives tenants that come up healthy
and completely empty.

## Platform objects via GitOps

Once Argo CD and the Platform are both up, the Platform's own objects are managed from Git
rather than applied by hand:

```bash
kubectl apply -f gitops/bootstrap/platform-gitops-app.yaml
```

That single Application recursively syncs `gitops/`, which holds the Project, the Cluster
annotations, both templates, and the tenant instances. Adding a tenant becomes a file in
`gitops/tenants/`. Ordering is sync waves, not separate Applications — the Project has to
exist before the tenants that live in its namespace. See [`gitops/README.md`](../gitops/README.md).

Note that `management.loft.sh` is served by the Platform's aggregated API server rather
than by CRDs, and it defaults fields on write, so Argo CD can report drift on fields it
never set. The bootstrap Application carries an `ignoreDifferences` block for the ones seen
so far.

## Argo CD application names are project-scoped

`deploy.argoCD.applications[].name` must be unique across the whole project, not just the
tenant. A static name works for one tenant and then fails on the second with:

```text
argocd application name "weblogic-domain" is already used by another tenant cluster
in this project
```

Template it with the tenant name:

```yaml
deploy:
  argoCD:
    applications:
      - name: '{{ .Values.loft.virtualClusterName }}-weblogic-domain'
```

Omitting `name` entirely also works — the Platform generates a unique one — but a
templated name stays readable in the Argo CD UI, which matters when several tenants are
on screen at once.

## What the connector does and does not cover

The connector's `server` governs one path: **Platform → Argo CD API**. An in-cluster
`http://` endpoint is only valid when Argo CD is co-located and running insecure. Argo CD
hosted elsewhere needs a reachable URL, real TLS, and `caData` for a private CA.

It does not govern how Argo CD reaches the clusters it deploys into. Platform registers
each cluster with **the Platform proxy as the API server endpoint** and a scoped access
key as the bearer token, so Argo CD never contacts a tenant API server directly. Adding
control plane clusters or tenant clusters is unaffected, and a remote control plane cluster
does not need its API server reachable from Argo CD.

What that path does depend on is Argo CD reaching `config.loftHost` — one more reason to
set it before creating tenants. When Argo CD runs inside the same cluster, those calls
hairpin out to the load balancer and back, which works because the Gateway uses
`nlb-target-type: ip`. Instance-target NLBs blackhole hairpinned traffic.
