{{/*
Create the name of the service account to use
*/}}
{{- define "kanidm.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "common.names.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "kanidm.adminSecretName" -}}
{{- default (printf "%s-admin" (include "common.names.fullname" .)) .Values.adminSecret.name }}
{{- end }}

{{- define "post-job.fullname" -}}
{{- printf "%s-post-job" (include "common.names.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "post-job.serviceAccountName" -}}
{{- if .Values.postJob.serviceAccount.create }}
{{- default (include "post-job.fullname" .) .Values.postJob.serviceAccount.name }}
{{- else }}
{{- default (include "kanidm.serviceAccountName" .) .Values.postJob.serviceAccount.name }}
{{- end }}
{{- end }}
