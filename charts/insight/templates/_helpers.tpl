{{/*
==============================================================================
 Umbrella helpers
==============================================================================
Центральное место для:
  - имени релиза/компонентов (DRY)
  - resolve service-ссылок (internal vs external) через enabled-gate
  - fail-fast валидаторы для обязательных полей

Любой шаблон, которому нужен host/port/URL зависимости — использует helper,
а не хардкодит имя. Если SRE скажет "переименуйте MariaDB в Galera" —
правим один файл.
==============================================================================
*/}}

{{- define "insight.fullname" -}}
{{- default .Release.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "insight.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: insight
{{- end -}}

{{/*
==============================================================================
 SERVICE RESOLUTION HELPERS
==============================================================================
Контракт: каждый helper отдаёт либо internal DNS (если сабчарт enabled),
либо значение из external.* (если enabled=false). Fail если external
не задан в отключённом режиме — ловим косяк до deploy'а.
==============================================================================
*/}}

{{/* ---------- ClickHouse ---------- */}}
{{- define "insight.clickhouse.host" -}}
{{- if .Values.clickhouse.enabled -}}
{{- printf "%s-clickhouse" .Release.Name -}}
{{- else -}}
{{- required "clickhouse.enabled=false requires clickhouse.external.host" .Values.clickhouse.external.host -}}
{{- end -}}
{{- end -}}

{{- define "insight.clickhouse.port" -}}
{{- if .Values.clickhouse.enabled -}}
8123
{{- else -}}
{{- .Values.clickhouse.external.port | default 8123 -}}
{{- end -}}
{{- end -}}

{{- define "insight.clickhouse.url" -}}
http://{{ include "insight.clickhouse.host" . }}:{{ include "insight.clickhouse.port" . }}
{{- end -}}

{{- define "insight.clickhouse.database" -}}
{{- .Values.clickhouse.database | default "insight" -}}
{{- end -}}

{{/* ---------- MariaDB ---------- */}}
{{- define "insight.mariadb.host" -}}
{{- if .Values.mariadb.enabled -}}
{{- printf "%s-mariadb" .Release.Name -}}
{{- else -}}
{{- required "mariadb.enabled=false requires mariadb.external.host" .Values.mariadb.external.host -}}
{{- end -}}
{{- end -}}

{{- define "insight.mariadb.port" -}}
{{- if .Values.mariadb.enabled -}}
3306
{{- else -}}
{{- .Values.mariadb.external.port | default 3306 -}}
{{- end -}}
{{- end -}}

{{- define "insight.mariadb.database" -}}
{{- if .Values.mariadb.enabled -}}
{{- .Values.mariadb.auth.database | default "insight" -}}
{{- else -}}
{{- .Values.mariadb.external.database | default "insight" -}}
{{- end -}}
{{- end -}}

{{/* ---------- Redis ---------- */}}
{{- define "insight.redis.host" -}}
{{- if .Values.redis.enabled -}}
{{- printf "%s-redis-master" .Release.Name -}}
{{- else -}}
{{- required "redis.enabled=false requires redis.external.host" .Values.redis.external.host -}}
{{- end -}}
{{- end -}}

{{- define "insight.redis.port" -}}
{{- if .Values.redis.enabled -}}
6379
{{- else -}}
{{- .Values.redis.external.port | default 6379 -}}
{{- end -}}
{{- end -}}

{{- define "insight.redis.url" -}}
redis://{{ include "insight.redis.host" . }}:{{ include "insight.redis.port" . }}
{{- end -}}

{{/* ---------- Redpanda ---------- */}}
{{- define "insight.redpanda.brokers" -}}
{{- if .Values.redpanda.enabled -}}
{{- printf "%s-redpanda:9092" .Release.Name -}}
{{- else -}}
{{- required "redpanda.enabled=false requires redpanda.external.brokers" .Values.redpanda.external.brokers -}}
{{- end -}}
{{- end -}}

{{/* ---------- App service DNS (always internal, always umbrella-managed) ---------- */}}
{{- define "insight.apiGateway.host"   -}}{{- printf "%s-api-gateway"           .Release.Name -}}{{- end -}}
{{- define "insight.analyticsApi.host" -}}{{- printf "%s-analytics-api"         .Release.Name -}}{{- end -}}
{{- define "insight.identity.host"     -}}{{- printf "%s-identity-resolution"  .Release.Name -}}{{- end -}}
{{- define "insight.frontend.host"     -}}{{- printf "%s-frontend"              .Release.Name -}}{{- end -}}

{{/*
==============================================================================
 VALIDATORS
==============================================================================
Fail-fast проверки. Срабатывают при `helm template`/install.
Вызываются из NOTES.txt (включается в каждый install-run).
==============================================================================
*/}}
{{- define "insight.validate" -}}
  {{- /* OIDC обязателен, если gateway включён и auth не отключён */ -}}
  {{- if and .Values.apiGateway.enabled (not .Values.apiGateway.authDisabled) -}}
    {{- if and (not .Values.apiGateway.oidc.existingSecret) (not .Values.apiGateway.oidc.issuer) -}}
      {{- fail "apiGateway.oidc: either existingSecret OR inline issuer+clientId+redirectUri must be set when authDisabled=false" -}}
    {{- end -}}
  {{- end -}}

  {{- /* External service refs проверятся helper'ами, но prompt здесь полезен */ -}}
  {{- if and (not .Values.clickhouse.enabled) (not .Values.clickhouse.external.host) -}}
    {{- fail "clickhouse.enabled=false requires clickhouse.external.host" -}}
  {{- end -}}
  {{- if and (not .Values.mariadb.enabled)    (not .Values.mariadb.external.host)    -}}
    {{- fail "mariadb.enabled=false requires mariadb.external.host" -}}
  {{- end -}}
  {{- if and (not .Values.redis.enabled)      (not .Values.redis.external.host)      -}}
    {{- fail "redis.enabled=false requires redis.external.host" -}}
  {{- end -}}
  {{- if and (not .Values.redpanda.enabled)   (not .Values.redpanda.external.brokers) -}}
    {{- fail "redpanda.enabled=false requires redpanda.external.brokers" -}}
  {{- end -}}
{{- end -}}
