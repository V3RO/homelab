locals {
  argocd_chart_path  = "${path.root}/../../k8s/infra/argocd/argo"
  argocd_values_path = "${path.root}/../../k8s/infra/argocd/argo/values.yaml"
  argo_config_chart_path  = "${path.root}/../../k8s/infra/argocd/argo-config"
  argo_config_values_path = "${path.root}/../../k8s/infra/argocd/argo-config/values.yaml"
}

# Wait for cluster health and Cilium readiness before installing Argo CD
resource "null_resource" "wait_for_cluster" {
  triggers = {
    cluster_health_version = uuid()
  }
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      set -euo pipefail
      echo "Waiting for Talos cluster health..."
      KUBECONFIG="${path.module}/output/kube-config.yaml"
      # Wait for kubectl to function
      for i in $(seq 1 60); do
        if kubectl --kubeconfig "$KUBECONFIG" get nodes >/dev/null 2>&1; then
          break
        fi
        sleep 5
        if [ "$i" -eq 60 ]; then
          echo "Timeout waiting for API..." >&2; exit 1
        fi
      done
      echo "API reachable. Checking node readiness..."
      for i in $(seq 1 60); do
        READY_COUNT=$(kubectl --kubeconfig "$KUBECONFIG" get nodes --no-headers | awk '/ Ready / {print $1}' | wc -l | tr -d ' ')
        if [ "$READY_COUNT" -ge 1 ]; then
          echo "At least one node ready, nodes: ($READY_COUNT)."
          break
        fi
        sleep 5
        if [ "$i" -eq 60 ]; then
          echo "Timeout waiting for node readiness..." >&2; exit 1
        fi
      done
      echo "Waiting for Cilium DaemonSet to be ready..."
      for i in $(seq 1 60); do
        DS_READY=$(kubectl --kubeconfig "$KUBECONFIG" -n kube-system get ds cilium -o jsonpath='{.status.numberReady}' 2>/dev/null || true)
        DS_DESIRED=$(kubectl --kubeconfig "$KUBECONFIG" -n kube-system get ds cilium -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || true)
        if [ -n "$DS_READY" ] && [ -n "$DS_DESIRED" ] && [ "$DS_READY" = "$DS_DESIRED" ] && [ "$DS_READY" != "" ]; then
          echo "Cilium pods ready ($DS_READY/$DS_DESIRED)."
          break
        fi
        sleep 5
        if [ "$i" -eq 60 ]; then
          echo "Timeout waiting for Cilium readiness" >&2; exit 1
        fi
      done
      echo "Cluster prerequisites satisfied."
    EOT
  }
  depends_on = [
    module.talos,
  ]
}

resource "null_resource" "argocd" {
  count = var.enable_argocd ? 1 : 0

  triggers = {
    # Re-run the install if the chart path or values change.
    # Using a file hash means changes to values.yaml trigger a re-install.
    values_hash = filesha256(local.argocd_values_path)
    chart_path  = local.argocd_chart_path
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    # Bootstrap install only — ArgoCD takes over its own lifecycle via the
    # infra ApplicationSet (wave 5) once the cluster is running. We use
    # `helm upgrade --install` so re-applying is idempotent.
    # Bootstrap overrides:
    #   - httproute.enabled=false : Istio Gateway doesn't exist yet (wave 4)
    #   - redis.enabled=true      : Valkey doesn't exist yet (wave 4); ArgoCD
    #                               self-reconciles to Valkey after wave 5
    command = <<-EOT
      set -euo pipefail
      helm upgrade --install argo ${local.argocd_chart_path} \
        --namespace argocd \
        --create-namespace \
        --values ${local.argocd_values_path} \
        --set argo-cd.server.httproute.enabled=false \
        --set argo-cd.redis.enabled=true \
        --set argo-cd.externalRedis.host="" \
        --set argo-cd.externalRedis.existingSecret="" \
        --set "argo-cd.dex.volumes=null" \
        --set "argo-cd.dex.volumeMounts=null" \
        --timeout 600s \
        --wait \
        --atomic \
        --kubeconfig ${path.module}/output/kube-config.yaml
    EOT
  }

  # destroy-time provisioner is intentionally omitted — ArgoCD's lifecycle
  # is managed by itself after bootstrap. `tofu destroy` will not attempt
  # to helm uninstall ArgoCD; tear-down is handled by destroying the cluster.

  depends_on = [null_resource.wait_for_cluster]
}

resource "null_resource" "argo_config" {
  count = var.enable_argocd ? 1 : 0

  triggers = {
    values_hash = filesha256(local.argo_config_values_path)
    chart_path  = local.argo_config_chart_path
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    # wait/atomic intentionally disabled: argo-config contains ExternalSecret CRs
    # (for ArgoCD's Authentik OIDC and Zot OCI repo credentials) which require
    # the external-secrets CRDs to exist. Those CRDs are only installed later by
    # ArgoCD itself. The ApplicationSet and ExternalSecrets are valid resources —
    # ArgoCD will reconcile the ExternalSecrets once external-secrets is running.
    command = <<-EOT
      set -euo pipefail
      helm upgrade --install argo-config ${local.argo_config_chart_path} \
        --namespace argocd \
        --values ${local.argo_config_values_path} \
        --timeout 600s \
        --disable-openapi-validation \
        --kubeconfig ${path.module}/output/kube-config.yaml
    EOT
  }

  depends_on = [null_resource.argocd]
}
