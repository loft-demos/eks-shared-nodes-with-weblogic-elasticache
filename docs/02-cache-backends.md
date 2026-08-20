# Cache backends

`cacheMode` on the tenant instance picks how a tenant gets Redis. The application is
identical across all three.

| Mode | Ready in | Needs AWS | For |
|---|---|---|---|
| `in-tenant` | seconds | no | Creating a tenant live; any non-AWS cluster |
| `elasticache` | 5-10 min | yes | The ACK self-service story |
| `none` | — | no | Tenants without a cache |

`in-tenant` is the default: most tenants are short-lived and only need *a* cache, so the
common case should not leave AWS billing behind when a tenant is forgotten.

## One contract, two backends

Both modes converge on a ConfigMap:

```yaml
data:
  endpoint: "..."     # hostname (ElastiCache) or ClusterIP (in-tenant)
  port: "6379"
  tls: "true"         # ElastiCache with encryption in transit; false for in-tenant
  state: "available"
  backend: "in-tenant"   # or "elasticache"
```

The WebLogic server pods mount it as a **directory** — never with `subPath`, which would
freeze the contents. kubelet refreshes a directory mount in place, so a running domain
picks up a newly provisioned cache with no restart. That matters: a WebLogic restart is
the slowest thing in this stack.

The servlet re-reads the files on a short TTL and reports `state` when there is no
endpoint yet, so the page moves from "provisioning" to a live counter on its own.

`backend` exists so the page describes what the tenant actually got. Without it the app
had to assume one backend, and an in-tenant tenant claimed to be running on ElastiCache.

A small publisher Deployment in the tenant fills the ConfigMap in. The chart seeds it
empty first, because a pod cannot start against a missing ConfigMap volume and AWS takes
minutes to answer.

It re-reads the live ConfigMap each cycle rather than trusting its own last write. Argo CD
re-applies every manifest on a sync, `ignoreDifferences` suppresses only drift *detection*,
so the seeded empty placeholder comes back periodically. Comparing against the API rather
than against memory makes that self-correcting instead of permanent.

## ElastiCache through ACK

The tenant creates a `ReplicationGroup`; vCluster syncs it up; the ACK controller
reconciles it against AWS and writes the endpoint into status; status syncs back down; the
publisher copies it into the ConfigMap.

`numNodeGroups: 1` with `replicasPerNodeGroup` is ACK's cluster-mode-**disabled** shape,
which puts a usable address at `status.nodeGroups[0].primaryEndpoint`. Cluster-mode-enabled
reports a `configurationEndpoint` instead and needs a cluster-aware client; the demo
servlet speaks plain RESP and does not follow `MOVED`.

Tenants supply only the replication group. Subnet group and security group are created
once by the platform team and passed in through `Cluster` annotations, so a tenant cannot
place a cache on an arbitrary subnet or open it to an arbitrary CIDR.

## Reaching an in-tenant cache {#reaching-an-in-tenant-cache}

The Redis pod runs in the tenant, but the WebLogic server pods do not: the operator
creates them on the Control Plane Cluster. They resolve names against host CoreDNS, where
a tenant Service name does not exist.

The publisher therefore writes the Service's **ClusterIP**, not its DNS name. vCluster
recreates the tenant Service so its ClusterIP matches the synced host Service, which makes
that address valid from both sides.

If a cache is reachable from `kubectl exec` inside the tenant but not from WebLogic, this
is the mechanism to check.

## Sleep Mode

Sleeping a tenant scales its workloads to zero. An `in-tenant` Redis stops with everything
else — no cost while asleep, but the cache is empty on wake. An `elasticache` group lives
outside the cluster, so it keeps its data and keeps billing.

`sleepmode.loft.sh/exclude: 'true'` on the Deployment keeps the in-tenant cache up, though
with an `emptyDir` behind it the data does not survive a pod restart anyway.

## No Redis driver in the WAR

The demo servlet talks RESP over a socket in about 150 lines rather than pulling in Jedis
or Lettuce, which would drag slf4j, gson, and commons-pool into `WEB-INF/lib` and start a
classloader argument with WebLogic. TLS uses the JDK truststore with hostname verification;
ElastiCache presents a publicly trusted Amazon certificate, so nothing extra is needed.
