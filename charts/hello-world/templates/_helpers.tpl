{{/* Chart name, overridable with nameOverride. */}}
{{- define "hello-world.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Fully qualified name, truncated to the 63-character label limit. */}}
{{- define "hello-world.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "hello-world.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Labels applied to every object. */}}
{{- define "hello-world.labels" -}}
helm.sh/chart: {{ include "hello-world.chart" . }}
{{ include "hello-world.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ include "hello-world.name" . }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* Selector labels. Immutable in the Deployment, so nothing version-dependent. */}}
{{- define "hello-world.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hello-world.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "hello-world.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "hello-world.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Image reference. A digest, when set, wins over the tag. */}}
{{- define "hello-world.image" -}}
{{- $repository := .Values.image.repository -}}
{{- if .Values.image.registry -}}
{{- $repository = printf "%s/%s" .Values.image.registry .Values.image.repository -}}
{{- end -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" $repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repository (default .Chart.AppVersion .Values.image.tag) -}}
{{- end -}}
{{- end }}

{{/* Name of the metrics Service. */}}
{{- define "hello-world.metricsServiceName" -}}
{{- printf "%s-metrics" (include "hello-world.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Absolute DNS name of the main Service. The trailing dot skips the search list. */}}
{{- define "hello-world.serviceFQDN" -}}
{{- printf "%s.%s.svc.%s." (include "hello-world.fullname" .) .Release.Namespace .Values.clusterDomain }}
{{- end }}

{{/* Guards for values that render valid YAML but misbehave at runtime. */}}
{{- define "hello-world.validateValues" -}}
{{- $drain := .Values.config.drainDelay | toString -}}
{{- $shutdown := .Values.config.shutdownTimeout | toString -}}
{{- if not (regexMatch "^[0-9]+(\\.[0-9]+)?(ns|us|ms|s|m|h)$" $drain) -}}
{{- fail (printf "config.drainDelay must be a Go duration such as 5s, got %q" $drain) -}}
{{- end -}}
{{- if not (regexMatch "^[0-9]+(\\.[0-9]+)?(ns|us|ms|s|m|h)$" $shutdown) -}}
{{- fail (printf "config.shutdownTimeout must be a Go duration such as 15s, got %q" $shutdown) -}}
{{- end -}}
{{- if and .Values.podDisruptionBudget.enabled .Values.podDisruptionBudget.minAvailable .Values.podDisruptionBudget.maxUnavailable -}}
{{- fail "set only one of podDisruptionBudget.minAvailable or podDisruptionBudget.maxUnavailable" -}}
{{- end -}}
{{/* A PDB allowing no disruption blocks node drains forever. */}}
{{- if and .Values.podDisruptionBudget.enabled .Values.podDisruptionBudget.minAvailable -}}
{{- $replicas := int .Values.replicaCount -}}
{{- if .Values.autoscaling.enabled -}}
{{- $replicas = int .Values.autoscaling.minReplicas -}}
{{- end -}}
{{- if ge (int .Values.podDisruptionBudget.minAvailable) $replicas -}}
{{- fail (printf "podDisruptionBudget.minAvailable (%d) must be less than the replica count (%d), otherwise no pod can ever be evicted and node drains will hang" (int .Values.podDisruptionBudget.minAvailable) $replicas) -}}
{{- end -}}
{{- end -}}
{{- end }}
