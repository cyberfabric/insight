{{/*
Fullname = "<release>-frontend", а не просто "<release>". Иначе при установке
под umbrella chart (release = "insight") имя коллизирует с другими ресурсами,
которые тоже биндятся на "insight".
*/}}
{{- define "insight-frontend.fullname" -}}
{{- printf "%s-frontend" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "insight-frontend.labels" -}}
app.kubernetes.io/name: insight-frontend
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "insight-frontend.selectorLabels" -}}
app.kubernetes.io/name: insight-frontend
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
