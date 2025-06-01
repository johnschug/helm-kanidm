#!/bin/bash
set -eux

fullname={{ include "common.names.fullname" . | quote }}
namespace={{ include "common.names.namespace" . | quote }}
release={{ .Release.Name }}
adminSecret={{ include "kanidm.adminSecretName" . | quote }}

cd $(mktemp -d)

curl -sSL https://dl.k8s.io/release/v1.33.0/bin/linux/amd64/kubectl -o /usr/local/bin/kubectl
curl -sSL https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 -o /usr/local/bin/jq
chmod +x /usr/local/bin/{kubectl,jq}

export HOME="$(pwd)"
export KANIDM_URL="https://$fullname.$namespace.svc.cluster.local:{{ .Values.service.ports.https }}/"
export KANIDM_CA_PATH="/certs/ca.crt"
export KUBECONFIG="$(pwd)/.kubeconfig"

function kubectl() {
  command /usr/local/bin/kubectl --namespace="$namespace" "$@"
}

kubectl config set-cluster cfc --server=https://kubernetes.default.svc --certificate-authority=/service-account/ca.crt
kubectl config set-context cfc --cluster=cfc
set +x
kubectl config set-credentials user --token="$(</service-account/token)"
set -x
kubectl config set-context cfc --user=user
kubectl config use-context cfc

# Recover admin secrets
if [[ -s "/secrets/idm_admin" ]] && [[ -s "/secrets/system_admin" ]]; then
  cp /secrets/idm_admin ./
else
  kubectl exec sts/"$fullname" -- kanidmd recover-account idm_admin -o json | grep password | jq -r .password  >./idm_admin
  kubectl exec sts/"$fullname" -- kanidmd recover-account admin -o json | grep password | jq -r .password  >./system_admin
  # kubectl exec sts/"$fullname" -- kanidmd recover-account admin -o json | sed -n -E '/new_password/{s/[^"]*"([^"]*)"/\1/; p}' >./system_admin
  kubectl patch secret "$adminSecret" --patch-file /dev/stdin <<EOP
  data:
    idm_admin: "$(base64 ./idm_admin)"
    system_admin: "$(base64 ./system_admin)"
EOP
  # kubectl create secret generic "$adminSecret" --from-file=idm_admin=./idm_admin --from-file=system_admin=./system_admin --dry-run=client --output=yaml | kubectl apply -f -
fi

set +x
kanidm login --name idm_admin --password "$(<./idm_admin)"
set -x

# Create/Modify groups
{{- range .Values.groups }}
grpName={{ .name | quote }}
if kanidm group get --name idm_admin "$grpName" 2>&1 | grep -q "No matching group"; then
  kanidm group create --name idm_admin "$grpName"
fi

# Idempotent
{{- range .memberOf }}
kanidm group add-members --name idm_admin {{ . | quote }} "$grpName"
{{- end }}
{{- end }}

# Create/Modify users
{{- range .Values.users }}
userName={{ .name | quote }}
if kanidm person get --name idm_admin "$userName" 2>& 1| grep -q "No matching entries"; then
  kanidm person create --name idm_admin "$userName" {{ .displayName | quote }}
else
  kanidm person update --name idm_admin --displayname {{ .displayName | quote }} "$userName"
fi

{{- if .email }}
kanidm person update --name idm_admin --mail {{ .email | quote }} "$userName"
{{- end }}

# Idempotent
{{- range .groups }}
kanidm group add-members --name idm_admin {{ . | quote }} "$userName"
{{- end }}
{{- end }}

# Create/Modify oauth2 clients
{{- range .Values.oauth2 }}
clientName="{{ .name }}"
if kanidm system oauth2 get --name idm_admin "$clientName" 2>&1 | grep -q "No matching entries"; then
  action={{ .public | default false | ternary "create-public" "create" }}
  kanidm system oauth2 "$action" --name idm_admin "$clientName" {{ .displayName | quote }} {{ .landingPage | quote }}
else
  kanidm system oauth2 set-displayname --name idm_admin "$clientName" {{ .displayName | quote }}
  kanidm system oauth2 set-landing-url --name idm_admin "$clientName" {{ .landingPage | quote }}
fi

{{- if .localhost }}
kanidm system oauth2 enable-localhost-redirects --name idm_admin "$clientName"
{{- end }}

{{- if .insecureDisablePkce }}
kanidm system oauth2 warning-insecure-client-disable-pkce --name idm_admin "$clientName"
{{- end }}

{{- range .redirects }}
kanidm system oauth2 add-redirect-url --name idm_admin "$clientName" {{ . | quote }}
{{- end }}

{{- range $grp, $scopes := .scopes }}
kanidm system oauth2 update-scope-map --name idm_admin "$clientName" {{ $grp | quote }} {{ $scopes | join " " }}
{{- end }}

{{- range .customClaims }}
kanidm system oauth2 update-claim-map --name idm_admin "$clientName" {{ .name | quote }} {{ .group | quote }} {{ .values | join " " }}
{{- end }}

{{- if .secret }}
secret=$(kanidm system oauth2 show-basic-secret --name idm_admin "$clientName" -o json | jq -r .secret)
if [ -n "$secret" ]; then
  kubectl patch secret {{ .secret.name | quote }} --patch-file /dev/stdin <<EOP
  data:
    {{- .secret.key | quote | nindent 4 }}: $(printf '%s' "$secret" | base64)
EOP
fi
{{- end }}
{{- end }}
