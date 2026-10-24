{{- range .Values.components }}
{{- if and .repository .source }}
{{- fail (printf "%s: set repository or source, not both" .name) }}
{{- end }}
{{- if not (or .repository .source) }}
{{- fail (printf "%s: repository or source is required" .name) }}
{{- end }}
{{- if not .chart }}
{{- fail (printf "%s: chart is required" .name) }}
{{- end }}
{{- $vals := .values | default dict }}
{{- if .valuesKey }}
{{- $vals = index $.Values .valuesKey }}
{{- if not $vals }}
{{- fail (printf "%s: valuesKey %s is missing" .name .valuesKey) }}
{{- end }}
{{- end }}
{{- if .repository }}
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: {{ .name }}
  namespace: {{ .namespace }}
spec:
  interval: {{ .repoInterval | default "24h" }}
  url: {{ .repository | quote }}
{{- end }}
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: {{ .name }}
  namespace: {{ .namespace }}
spec:
  interval: {{ .interval | default "10m" }}
  chart:
    spec:
      chart: {{ .chart }}
      {{- with .version }}
      version: {{ . | quote }}
      {{- end }}
      sourceRef:
        {{- if .repository }}
        kind: HelmRepository
        name: {{ .name }}
        namespace: {{ .namespace }}
        {{- else }}
        kind: GitRepository
        name: {{ .source }}
        namespace: flux-system
        {{- end }}
      interval: {{ .chartInterval | default "12h" }}
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
  values:
    {{- include "component.values" (dict "values" $vals "schedule" .schedule "scheduleAt" .scheduleAt) | nindent 4 }}
{{- end }}
