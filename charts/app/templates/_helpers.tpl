{{/*
Host derivation — the ONE place a full hostname is ever assembled.
  subdomain set  -> "<subdomain>.<baseDomain>"
  subdomain ""   -> "<baseDomain>" (apex)
baseDomain is injected by the tenant (Flux postBuild.substitute); required.
*/}}
{{- define "app.host" -}}
{{- $base := required "global.baseDomain is required (injected by the tenant)" .Values.global.baseDomain -}}
{{- if .Values.subdomain -}}
{{ .Values.subdomain }}.{{ $base }}
{{- else -}}
{{ $base }}
{{- end -}}
{{- end -}}

{{/*
Tier -> Traefik entrypoint.
  private / private-auth -> tailnet
  public  / public-auth  -> websecure
*/}}
{{- define "app.entrypoint" -}}
{{- if hasPrefix "private" .Values.tier -}}tailnet{{- else -}}websecure{{- end -}}
{{- end -}}

{{/*
Tier -> Traefik middlewares (comma-joined @kubernetescrd refs).
  public*  -> ratelimit + inflight
  *-auth   -> + forward-auth
  private (no auth) -> none
*/}}
{{- define "app.middlewares" -}}
{{- $mw := list -}}
{{- if hasPrefix "public" .Values.tier -}}
{{- $mw = append $mw "security-ratelimit@kubernetescrd" -}}
{{- $mw = append $mw "security-inflight@kubernetescrd" -}}
{{- end -}}
{{- if hasSuffix "auth" .Values.tier -}}
{{- $mw = append $mw "security-forward-auth@kubernetescrd" -}}
{{- end -}}
{{- join "," $mw -}}
{{- end -}}

{{/* Whether this app serves a static site (either inline HTML or an existing ConfigMap). */}}
{{- define "app.hasSite" -}}
{{- if .Values.site -}}
{{- if or .Values.site.indexHtml .Values.site.existingConfigMap -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{/* Name of the ConfigMap to mount as the site (existing one, or the chart-generated one). */}}
{{- define "app.siteConfigMap" -}}
{{- if and .Values.site .Values.site.existingConfigMap -}}
{{ .Values.site.existingConfigMap }}
{{- else -}}
{{ .Values.name }}-site
{{- end -}}
{{- end -}}
