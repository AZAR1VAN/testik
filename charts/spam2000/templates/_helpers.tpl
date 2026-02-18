{{/*
Expand the name of the chart.
*/}}
{{- define "spam2000.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "spam2000.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "spam2000.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{ include "spam2000.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "spam2000.selectorLabels" -}}
app.kubernetes.io/name: {{ include "spam2000.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
