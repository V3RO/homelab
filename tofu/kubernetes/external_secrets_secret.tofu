locals {
  external_secrets_namespace = "external-secrets"
}

resource "null_resource" "wait_for_external_secrets_ns" {
  count = var.enable_argocd && var.bitwarden_access_token != "" ? 1 : 0
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      set -euo pipefail
      KUBECONFIG="${path.module}/output/kube-config.yaml"
      echo "Waiting for namespace '${local.external_secrets_namespace}' to exist before creating Bitwarden secret..."
      for i in $(seq 1 60); do
        if kubectl --kubeconfig "$KUBECONFIG" get ns ${local.external_secrets_namespace} >/dev/null 2>&1; then
          echo "Namespace ${local.external_secrets_namespace} found."; break
        fi
        sleep 5
        if [ "$i" -eq 60 ]; then
          echo "Timeout waiting for namespace ${local.external_secrets_namespace}..." >&2; exit 1
        fi
      done
    EOT
  }
  depends_on = [
    helm_release.argo_config,
  ]
}

resource "kubernetes_secret" "bitwarden_access_token" {
  count = var.enable_argocd && var.bitwarden_access_token != "" ? 1 : 0
  metadata {
    name      = "bitwarden-access-token"
    namespace = local.external_secrets_namespace
  }
  data = {
    token = var.bitwarden_access_token
  }
  type = "Opaque"
  depends_on = [null_resource.wait_for_external_secrets_ns]
}

output "bitwarden_secret_created" {
  value       = var.enable_argocd && var.bitwarden_access_token != "" ? true : false
  description = "True if Bitwarden access token secret was created"
  sensitive   = true
}
