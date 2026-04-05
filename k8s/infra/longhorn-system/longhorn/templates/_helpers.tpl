{{- /*
  longhorn.quantityToBytes converts a Kubernetes storage quantity string to an
  integer byte count string, as required by the Longhorn Volume CRD spec.size
  field. Longhorn rejects Kubernetes quantity notation (e.g. "2Gi") and expects
  a plain base-10 integer string (e.g. "2147483648").

  Supported suffixes (binary IEC units only — covers all practical homelab sizes):
    Mi  →  1048576          (2^20)
    Gi  →  1073741824       (2^30)
    Ti  →  1099511627776    (2^40)
*/ -}}
{{- define "longhorn.quantityToBytes" -}}
  {{- $q := . -}}
  {{- if hasSuffix "Ti" $q -}}
    {{- $n := trimSuffix "Ti" $q | int64 -}}
    {{- mul $n 1099511627776 | toString -}}
  {{- else if hasSuffix "Gi" $q -}}
    {{- $n := trimSuffix "Gi" $q | int64 -}}
    {{- mul $n 1073741824 | toString -}}
  {{- else if hasSuffix "Mi" $q -}}
    {{- $n := trimSuffix "Mi" $q | int64 -}}
    {{- mul $n 1048576 | toString -}}
  {{- else -}}
    {{- fail (printf "longhorn.quantityToBytes: unsupported suffix in %q (use Mi, Gi, or Ti)" $q) -}}
  {{- end -}}
{{- end -}}

{{- define "longhorn.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
