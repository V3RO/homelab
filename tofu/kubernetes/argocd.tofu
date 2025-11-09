locals {
  argocd_chart_path  = "${path.root}/../../k8s/apps/argocd/argo"
  argocd_values_path = "${path.root}/../../k8s/apps/argocd/argo/values.yaml"
  argo_config_chart_path  = "${path.root}/../../k8s/apps/argocd/argo-config"
  argo_config_values_path = "${path.root}/../../k8s/apps/argocd/argo-config/values.yaml"
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

resource "helm_release" "argocd" {
  count             = var.enable_argocd ? 1 : 0
  name              = "argo"
  namespace         = "argocd"
  create_namespace  = true
  chart             = local.argocd_chart_path
  values            = [file(local.argocd_values_path)]
  timeout           = 600
  wait              = true
  atomic            = true

  depends_on = [null_resource.wait_for_cluster]
}

resource "helm_release" "argo_config" {
  count            = var.enable_argocd ? 1 : 0
  name             = "argo-config"
  namespace        = "argocd"
  create_namespace = false
  chart            = local.argo_config_chart_path
  values           = [file(local.argo_config_values_path)]
  timeout          = 600
  wait             = true
  atomic           = true

  depends_on = [helm_release.argocd]
}
