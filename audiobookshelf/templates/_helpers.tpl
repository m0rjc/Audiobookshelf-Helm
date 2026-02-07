{{- define "audiobookshelf.name" -}}
audiobookshelf
{{- end -}}

{{- define "audiobookshelf.fullname" -}}
{{ .Release.Name }}-audiobookshelf
{{- end -}}

{{- define "audiobookshelf.labels" -}}
app.kubernetes.io/name: {{ include "audiobookshelf.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "audiobookshelf.selectorLabels" -}}
app.kubernetes.io/name: {{ include "audiobookshelf.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
