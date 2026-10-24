{{- define "component.values" -}}
{{- $vals := deepCopy (.values | default dict) -}}
{{- if .scheduleAt -}}
{{- $schedule := .schedule | default "worker" -}}
{{- if eq .scheduleAt "podAnnotations" -}}
{{- $ann := get $vals "podAnnotations" | default dict | deepCopy -}}
{{- $_ := set $ann "bagan.io/schedule" $schedule -}}
{{- $_ := set $vals "podAnnotations" $ann -}}
{{- else if eq .scheduleAt "deployment.podAnnotations" -}}
{{- $dep := get $vals "deployment" | default dict | deepCopy -}}
{{- $ann := get $dep "podAnnotations" | default dict | deepCopy -}}
{{- $_ := set $ann "bagan.io/schedule" $schedule -}}
{{- $_ := set $dep "podAnnotations" $ann -}}
{{- $_ := set $vals "deployment" $dep -}}
{{- else -}}
{{- fail (printf "scheduleAt %s is not supported" .scheduleAt) -}}
{{- end -}}
{{- end -}}
{{- $vals | toYaml -}}
{{- end -}}
