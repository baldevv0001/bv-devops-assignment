{{/*
Chart name, overridable with nameOverride.
*/}}
{{- define "hello-world.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified resource name. Truncated to 63 characters because that is the
limit for a Kubernetes label value, and this name is used as one.
*/}}
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

{{/*
Labels applied to every object.
*/}}
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

{{/*
Selector labels. These end up in an immutable Deployment selector, so they must
never include anything that changes between upgrades — a chart or app version
here would make every upgrade fail.
*/}}
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

{{/*
Full image reference. A digest, when supplied, wins over the tag so that a
release is pinned to exact content rather than to a mutable pointer.
*/}}
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

{{/*
Name of the metrics Service.
*/}}
{{- define "hello-world.metricsServiceName" -}}
{{- printf "%s-metrics" (include "hello-world.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully-qualified DNS name of the main Service, with a trailing dot.

The trailing dot makes the name absolute, so the resolver looks it up once and
skips the search list entirely. Without it a short name is tried against each
search domain and then, on some resolvers, as a bare absolute name — a query
that leaves the cluster and stalls for the full DNS timeout wherever the
upstream resolver is unreachable, which is the normal situation for a local
kind cluster behind WSL.
*/}}
{{- define "hello-world.serviceFQDN" -}}
{{- printf "%s.%s.svc.%s." (include "hello-world.fullname" .) .Release.Namespace .Values.clusterDomain }}
{{- end }}

{{/*
Guard against configurations that render valid YAML but misbehave at runtime.
Failing at template time turns a silent production problem into an install
error with an explanation.
*/}}
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
{{/*
A PDB that permits no disruption at all blocks node drains indefinitely, which
turns a routine cluster upgrade into an outage of its own.
*/}}
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
