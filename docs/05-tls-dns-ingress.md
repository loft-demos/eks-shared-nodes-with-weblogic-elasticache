# TLS, DNS, and ingress

One Gateway, one wildcard certificate, one DNS record. Adding a tenant needs no
certificate work and no DNS work.

```
*.apps.example.com ──▶ NLB ──▶ Envoy Gateway ──┬─▶ tenant HTTPRoutes
                                                ├─▶ Platform UI
                                                └─▶ Argo CD UI
```

## Envoy Gateway and the load balancer

[`examples/shared-gateway.yaml`](../examples/shared-gateway.yaml) carries an `EnvoyProxy`,
a `GatewayClass` referencing it via `parametersRef`, and the `Gateway` itself.

The AWS load balancer annotations go on the **`EnvoyProxy`**, under
`provider.kubernetes.envoyService.annotations`. That is Envoy Gateway's documented
mechanism for customizing the generated Service. The Gateway's own
`spec.infrastructure.annotations` is Gateway API surface that Envoy Gateway does not
document as supported for this, and getting it wrong yields a Classic LB with no
annotations.

`aws-load-balancer-type: external` is what hands the Service to the AWS Load Balancer
Controller rather than the legacy in-tree provider. `nlb-target-type: ip` matters beyond
performance — see the hairpin note in [04](04-platform-and-gitops.md).

The HTTPS listener references a Secret that does not exist until the certificate issues,
so the Gateway reports `Programmed=False` until then. That is expected.

## cert-manager

DNS01, not HTTP01: the demo needs a wildcard covering every tenant hostname, and HTTP01
cannot issue wildcards.

cert-manager picks up its Route 53 credentials as ambient environment credentials from its
Pod Identity association, so the `route53` solver block needs no `accessKeyID` or secret —
only `region` and `hostedZoneID`, the latter so the role does not need
`route53:ListHostedZonesByName`.

The `Certificate` lives in the Gateway's namespace, because `certificateRefs` resolve
there and anywhere else would need a `ReferenceGrant`.

**`READY=True` does not mean the certificate is trusted.** A Let's Encrypt staging
certificate reports Ready exactly like a production one and browsers reject it. Check who
signed it:

```bash
kubectl -n envoy-gateway-system get secret apps-wildcard-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer
```

`(STAGING)` in the issuer means you are still on staging. Switching means changing
`issuerRef` in the Certificate — deleting the Secret alone just reissues from whatever
issuer the Certificate still names.

A wildcard plus the apex on one certificate produces **two** ACME challenges writing
different values to the same `_acme-challenge` TXT record. cert-manager merges them and
waits for propagation, so expect roughly twice the issuance time of a single name.

## DNS

```bash
scripts/route53-record.sh
```

Resolves the Envoy Service by label — the name carries a per-Gateway hash — and upserts a
wildcard alias A record at the load balancer.

**Check what a hostname resolves to, not just that it resolves.** Under RFC 4592, a
wildcard higher in the zone answers for names at any depth beneath it. If
`*.example.com` already exists, `tenant.apps.example.com` resolves to *that* target before
your record exists, so the demo URL returns an unrelated application rather than failing.
`scripts/verify.sh` compares the resolved addresses against the Gateway's load balancer
for this reason.
