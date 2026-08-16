# Wait for cluster health and Cilium readiness before installing Flux
resource "null_resource" "wait_for_cluster" {
  triggers = {
    cluster_health_version = uuid()
  }
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
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

locals {
  # Keep in sync with the self-managing HelmRelease in
  # k8s/infra/flux-system/flux-operator, which adopts this release.
  flux_operator_chart_version = "0.58.0"
}

resource "null_resource" "flux_operator" {
  count = var.enable_gitops ? 1 : 0

  triggers = {
    # Re-install when the pinned operator chart version changes. The
    # self-managing HelmRelease takes over upgrades once Flux is up; this
    # trigger keeps fresh-cluster bootstrap on the same version.
    chart_version = local.flux_operator_chart_version
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      helm upgrade --install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
        --namespace flux-system \
        --create-namespace \
        --version ${local.flux_operator_chart_version} \
        --timeout 600s \
        --wait \
        --atomic \
        --kubeconfig ${path.module}/output/kube-config.yaml
    EOT
  }

  depends_on = [null_resource.wait_for_cluster]
}

resource "null_resource" "flux_bootstrap" {
  count = var.enable_gitops ? 1 : 0

  triggers = {
    # Re-apply whenever any bootstrap object changes.
    bootstrap_hash = sha256(join("", [
      for f in sort(fileset("${path.root}/../../k8s/bootstrap/flux", "**/*.yaml")) :
      filesha256("${path.root}/../../k8s/bootstrap/flux/${f}")
    ]))
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    # Retry: the FluxInstance CRD is registered by the operator install above,
    # but API discovery can lag briefly after helm reports ready.
    command = <<-EOT
      set -euo pipefail
      for i in $(seq 1 12); do
        if kubectl apply --server-side -k ${path.root}/../../k8s/bootstrap/flux \
          --kubeconfig ${path.module}/output/kube-config.yaml; then
          exit 0
        fi
        echo "kubectl apply attempt $i failed, retrying in 5s..." >&2
        sleep 5
      done
      echo "Bootstrap apply failed after 12 attempts" >&2
      exit 1
    EOT
  }

  depends_on = [null_resource.flux_operator]
}
