locals {
  # Only nodes that have a Longhorn disk configured get a data holder VM.
  longhorn_nodes = { for k, v in var.nodes : k => v if v.longhorn_disk_size > 0 }
}

# ---------------------------------------------------------------------------
# Longhorn data holder VMs
#
# Each node with longhorn_disk_size > 0 gets a companion "data VM" that owns
# the Longhorn storage disk. This VM is never started — its sole purpose is to
# own the disk image so the disk survives the destruction of the actual Talos
# node VM.
#
# VMID convention: data VM VMID = node VMID + 100.
#   e.g. ctrl-01 (800) → data VM (900)
#
# When the Talos node VM is destroyed and recreated (cluster rebuild), the data
# VM and its disk remain intact. The new Talos VM is then re-attached to the
# existing disk via the path_in_datastore attribute, and Longhorn finds its
# existing data on /var/lib/longhorn with no data loss.
#
# Disk serial convention: "lh-{vm_id}" (e.g. "lh-800" for ctrl-01).
# Inside the VM the disk is addressable via:
#   /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_lh-{vm_id}
# This stable path is referenced in the Talos machine config common.yaml.tftpl.
#
# CAUTION: prevent_destroy = true means a plain `tofu destroy` will FAIL.
# To intentionally decommission a node's Longhorn disk:
#   1. Remove the lifecycle block (or comment out prevent_destroy).
#   2. tofu apply  (updates the plan, no resource changes).
#   3. tofu destroy -target=module.longhorn_storage.proxmox_virtual_environment_vm.longhorn_data["<node>"]
#   4. Restore the lifecycle block.
# ---------------------------------------------------------------------------
resource "proxmox_virtual_environment_vm" "longhorn_data" {
  for_each = local.longhorn_nodes

  node_name = each.value.host_node

  name    = "${each.key}-longhorn-data"
  vm_id   = each.value.vm_id + 100
  tags    = ["k8s", "longhorn-data"]
  started = false
  on_boot = false

  # Minimal hardware — this VM is never booted. The cpu and memory blocks are
  # required by the provider but carry no operational significance here.
  cpu {
    cores = 1
  }

  memory {
    dedicated = 128
  }

  disk {
    datastore_id = each.value.datastore_id
    interface    = "scsi0"
    iothread     = true
    # cache = none: Longhorn manages its own caching per volume replica;
    # host-level caching on the raw block device adds no benefit and can
    # mask write errors.
    cache       = "none"
    discard     = "on"
    ssd         = true
    file_format = "raw"
    size        = each.value.longhorn_disk_size

    # Stable serial → stable /dev/disk/by-id path inside the Talos VM.
    # Format: "lh-{node_vm_id}" (max 20 chars, well within limit).
    # The Talos machine config references this as:
    #   /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_lh-<vm_id>
    serial = "lh-${each.value.vm_id}"
  }

  lifecycle {
    # Prevent accidental destruction of the disk data.
    # A plain `tofu destroy` will fail with an error — this is intentional.
    # See the CAUTION comment above for the decommission procedure.
    prevent_destroy = true

    # Ignore cosmetic attributes so routine cluster tofu runs don't show
    # spurious diffs on the data VM.
    ignore_changes = [description, tags, cpu, memory]
  }
}
