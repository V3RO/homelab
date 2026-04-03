resource "local_file" "talos_machine_configs" {
  for_each        = module.talos.machine_config
  content         = each.value.machine_configuration
  filename        = "output/talos-machine-config-${each.key}.yaml"
  file_permission = "0600"
}

resource "local_file" "talos_config" {
  content         = module.talos.client_configuration.talos_config
  filename        = "output/talos-config.yaml"
  file_permission = "0600"
}

resource "local_file" "kube_config" {
  content         = module.talos.kube_config.kubeconfig_raw
  filename        = "output/kube-config.yaml"
  file_permission = "0600"

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -euo pipefail
      KUBECONFIG="${self.filename}"
      echo "Waiting for all proxmox-csi PVs to be fully deleted before removing kubeconfig..."
      for i in $(seq 1 60); do
        COUNT=$(kubectl --kubeconfig "$KUBECONFIG" get pv \
          --no-headers -o custom-columns=NAME:.metadata.name,DRIVER:.spec.csi.driver 2>/dev/null \
          | awk '/csi\.proxmox\.sinextra\.dev/ {print $1}' | wc -l | tr -d ' ')
        if [ "$COUNT" -eq 0 ]; then
          echo "All proxmox-csi PVs are gone."
          exit 0
        fi
        echo "  $COUNT proxmox-csi PV(s) still present (attempt $i/60), waiting 5s..."
        sleep 5
      done
      echo "Timeout waiting for proxmox-csi PVs to be deleted." >&2
      exit 1
    EOT
  }
}

output "kube_config" {
  value     = module.talos.kube_config.kubeconfig_raw
  sensitive = true
}

output "talos_config" {
  value     = module.talos.client_configuration.talos_config
  sensitive = true
}
