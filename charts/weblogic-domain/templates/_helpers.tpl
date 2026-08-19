{{- define "weblogic-demo.namespace" -}}
{{- .Values.namespace | default "wi" -}}
{{- end -}}

{{- define "weblogic-demo.domainUID" -}}
{{- .Values.domainUID | default "wi-domain" -}}
{{- end -}}

{{- define "weblogic-demo.clusterName" -}}
{{- .Values.cluster.name | default "cluster-1" -}}
{{- end -}}

{{- define "weblogic-demo.clusterServiceName" -}}
{{ include "weblogic-demo.domainUID" . }}-cluster-{{ include "weblogic-demo.clusterName" . }}
{{- end -}}

{{/*
Name of the ConfigMap that carries the ElastiCache connection details.
The chart always creates it as a placeholder so the WebLogic server pods can mount it
before AWS has finished provisioning the replication group.
*/}}
{{- define "weblogic-demo.cacheConfigMapName" -}}
{{ include "weblogic-demo.domainUID" . }}-cache-endpoint
{{- end -}}

{{- define "weblogic-demo.cachePublisherName" -}}
{{ include "weblogic-demo.domainUID" . }}-cache-publisher
{{- end -}}

{{- define "weblogic-demo.replicationGroupID" -}}
{{- .Values.elasticache.replicationGroupID | default (printf "%s-cache" (include "weblogic-demo.domainUID" .)) -}}
{{- end -}}

{{/* True when this tenant should get a cache of any kind. */}}
{{- define "weblogic-demo.cacheEnabled" -}}
{{- if ne .Values.cache.mode "none" -}}true{{- end -}}
{{- end -}}

{{- define "weblogic-demo.isElastiCache" -}}
{{- if eq .Values.cache.mode "elasticache" -}}true{{- end -}}
{{- end -}}

{{- define "weblogic-demo.isInTenantCache" -}}
{{- if eq .Values.cache.mode "in-tenant" -}}true{{- end -}}
{{- end -}}

{{/*
Service fronting the in-tenant Redis. The WebLogic pods reach it by ClusterIP rather than
by name: they are created on the Control Plane Cluster by the operator, so they use host
DNS and cannot resolve a tenant Service name. vCluster recreates the tenant Service with
the host Service's ClusterIP, so that address is valid on both sides.
*/}}
{{- define "weblogic-demo.cacheServiceName" -}}
{{ include "weblogic-demo.domainUID" . }}-redis
{{- end -}}
