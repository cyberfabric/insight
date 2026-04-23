{{/*
Fullname helper. Ранее StatefulSet и Service использовали просто
`{{ .Release.Name }}`, что под umbrella chart-ом даёт имя коллизирующее
с другими ресурсами (frontend и clickhouse оба клались на "insight").

Теперь имя = "<release>-clickhouse". Совместимо с umbrella-конвенцией.

Если `fullnameOverride` задан — используем его; иначе <release>-<chartname>.
*/}}
{{- define "clickhouse.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "clickhouse.labels" -}}
app.kubernetes.io/name: clickhouse
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "clickhouse.selectorLabels" -}}
app.kubernetes.io/name: clickhouse
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
