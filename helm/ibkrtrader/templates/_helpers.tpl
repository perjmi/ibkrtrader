{{/*
Expand the name of the chart.
*/}}
{{- define "ibkrtrader.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name. Truncated at 63 chars.
*/}}
{{- define "ibkrtrader.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Chart label.
*/}}
{{- define "ibkrtrader.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels.
*/}}
{{- define "ibkrtrader.labels" -}}
helm.sh/chart: {{ include "ibkrtrader.chart" . }}
{{ include "ibkrtrader.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: ibkrtrader
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end -}}

{{/*
Selector labels.
*/}}
{{- define "ibkrtrader.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ibkrtrader.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Service account name.
*/}}
{{- define "ibkrtrader.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "ibkrtrader.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Active gateway service hostname based on .Values.ibkr.mode.
Strategies and the risk gateway use this to find IBGW.
*/}}
{{- define "ibkrtrader.activeGatewayHost" -}}
{{- printf "%s-ibgw-%s.%s.svc.cluster.local" (include "ibkrtrader.fullname" .) .Values.ibkr.mode .Release.Namespace -}}
{{- end -}}

{{- define "ibkrtrader.activeGatewayPort" -}}
{{- if eq .Values.ibkr.mode "live" -}}
{{- .Values.ibkr.gateways.live.apiPort -}}
{{- else -}}
{{- .Values.ibkr.gateways.paper.apiPort -}}
{{- end -}}
{{- end -}}

{{/*
Internal NATS DNS (the subchart's service).
*/}}
{{- define "ibkrtrader.natsHost" -}}
{{- printf "%s-nats.%s.svc.cluster.local" .Release.Name .Release.Namespace -}}
{{- end -}}

{{/*
Postgres host — the CNPG Cluster's read-write service.
*/}}
{{- define "ibkrtrader.pgHost" -}}
{{- printf "%s-timescale-rw.%s.svc.cluster.local" (include "ibkrtrader.fullname" .) .Release.Namespace -}}
{{- end -}}

{{/*
Validate that all enabled strategies have unique clientIds.
Fails template rendering with a clear error if duplicates are found.
*/}}
{{- define "ibkrtrader.validateClientIds" -}}
{{- $seen := dict -}}
{{- range $i, $s := .Values.strategies -}}
  {{- if $s.enabled -}}
    {{- if not $s.clientId -}}
      {{- fail (printf "strategy[%d] %q is missing clientId" $i $s.name) -}}
    {{- end -}}
    {{- $key := printf "%v" $s.clientId -}}
    {{- if hasKey $seen $key -}}
      {{- fail (printf "duplicate IBKR clientId %v on strategies %q and %q" $s.clientId (index $seen $key) $s.name) -}}
    {{- end -}}
    {{- $_ := set $seen $key $s.name -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Standard env block for any pod that needs to reach IBGW + NATS + Postgres.
*/}}
{{- define "ibkrtrader.commonEnv" -}}
- name: IBGW_HOST
  value: {{ include "ibkrtrader.activeGatewayHost" . | quote }}
- name: IBGW_PORT
  value: {{ include "ibkrtrader.activeGatewayPort" . | quote }}
- name: NATS_URL
  value: {{ printf "nats://%s:4222" (include "ibkrtrader.natsHost" .) | quote }}
- name: PG_HOST
  value: {{ include "ibkrtrader.pgHost" . | quote }}
- name: PG_DATABASE
  value: {{ .Values.timescale.cluster.bootstrap.database | quote }}
- name: IBKR_ACCOUNT
  value: {{ .Values.ibkr.account | quote }}
- name: IBKR_MODE
  value: {{ .Values.ibkr.mode | quote }}
{{- end -}}
