# Wait for cluster health and Cilium readiness before installing Flux
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

resource "null_resource" "flux_install" {
  count = var.enable_gitops ? 1 : 0

  triggers = {
    install_version = "1"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      set -euo pipefail
      helm repo add fluxcd-community https://fluxcd-community.github.io/helm-charts || true
      helm repo update fluxcd-community
      helm upgrade --install flux2 fluxcd-community/flux2 \
        --namespace flux-system \
        --create-namespace \
        --version 2.13.0 \
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
    gitrepository_hash = filesha256("${path.root}/../../k8s/bootstrap/flux/gitrepository.yaml")
    infra_sync_hash    = filesha256("${path.root}/../../k8s/bootstrap/flux/infra-sync.yaml")
    kustomization_hash = filesha256("${path.root}/../../k8s/bootstrap/flux/kustomization.yaml")
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      set -euo pipefail
      kubectl apply -k ${path.root}/../../k8s/bootstrap/flux \
        --kubeconfig ${path.module}/output/kube-config.yaml
    EOT
  }

  depends_on = [null_resource.flux_install]
}
