# ---------------------------------------------------------------------------
# Longhorn storage — persistent data holder VMs
#
# Creates one never-started "data VM" per node that has longhorn_disk_size > 0.
# The data VM owns the Longhorn storage disk; the Talos node VM attaches it
# via path_in_datastore. This means the disk survives a full cluster teardown
# and is automatically re-attached when the cluster is rebuilt.
#
# Data VM VMID convention: node VMID + 100  (e.g. ctrl-01 800 → data VM 900)
#
# CAUTION: prevent_destroy = true is set on data VMs. A plain `tofu destroy`
# will fail. Use targeted destroys or temporarily remove the lifecycle block
# when intentionally decommissioning. This is by design.
# ---------------------------------------------------------------------------
module "longhorn_storage" {
  source = "./longhorn-storage"

  providers = {
    proxmox = proxmox
  }

  nodes = var.talos_nodes
}

module "talos" {
  depends_on = [module.longhorn_storage]
  source     = "./talos"

  providers = {
    proxmox = proxmox
  }

  image          = var.talos_image
  cluster        = var.talos_cluster_config
  nodes          = var.talos_nodes
  longhorn_disks = module.longhorn_storage.disks
}
