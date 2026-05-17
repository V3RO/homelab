resource "proxmox_virtual_environment_vm" "this" {
  for_each = var.nodes

  node_name = each.value.host_node

  name        = each.key
  description = each.value.machine_type == "controlplane" ? "Talos Control Plane" : "Talos Worker"
  tags        = each.value.machine_type == "controlplane" ? ["k8s", "control-plane"] : ["k8s", "worker"]
  on_boot     = true
  vm_id       = each.value.vm_id

  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"
  bios          = "seabios"

  agent {
    enabled = true
  }

  cpu {
    cores = each.value.cpu
    type  = "host"
  }

  memory {
    dedicated = each.value.ram_dedicated
  }

  network_device {
    bridge      = "vmbr0"
    mac_address = each.value.mac_address
    vlan_id     = each.value.vlan_id
  }

  disk {
    datastore_id = each.value.datastore_id
    interface    = "scsi0"
    iothread     = true
    cache        = "writethrough"
    discard      = "on"
    ssd          = true
    file_format  = "raw"
    size         = 50
    file_id      = proxmox_virtual_environment_download_file.this["${each.value.host_node}_${each.value.update == true ? local.static_update_image_key : local.static_image_key}"].id
  }

  # Longhorn storage disk (scsi1 → /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_lh-{vm_id}).
  #
  # This disk is NOT created by this resource. It is owned by the companion
  # "data holder" VM (vm_id + 100) managed by the longhorn-storage module.
  # We attach it here via path_in_datastore (Experimental bpg/proxmox feature).
  #
  # Because the disk is owned by the data VM, destroying and recreating this
  # node VM leaves the disk — and all Longhorn volume data — intact.
  # On rebuild, tofu re-attaches the existing disk automatically.
  #
  # The serial (e.g. "lh-800") is carried through from the data VM so that
  # QEMU presents the device with the same serial inside the guest, keeping
  # the /dev/disk/by-id path stable across VM recreations.
  dynamic "disk" {
    for_each = each.value.longhorn_disk_size > 0 ? [var.longhorn_disks[each.key]] : []
    content {
      datastore_id      = disk.value.datastore_id
      path_in_datastore = disk.value.path_in_datastore
      file_format       = disk.value.file_format
      size              = disk.value.size
      interface         = "scsi1"
      serial            = disk.value.serial
      iothread          = true
      cache             = "none"
      discard           = "on"
      ssd               = true
    }
  }

  boot_order = ["scsi0"]

  operating_system {
    type = "l26" # Linux Kernel 2.6 - 6.X.
  }

  initialization {
    datastore_id = each.value.datastore_id

    # Optional DNS Block.  Update Nodes with a list value to use.
    dynamic "dns" {
      for_each = try(each.value.dns, null) != null ? { "enabled" = each.value.dns } : {}
      content {
        servers = each.value.dns
      }
    }

    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.cluster.subnet_mask}"
        gateway = var.cluster.gateway

      }
    }
  }

  dynamic "hostpci" {
    for_each = each.value.igpu ? [1] : []
    content {
      # Passthrough iGPU
      device  = "hostpci0"
      mapping = "iGPU"
      pcie    = true
      rombar  = true
      xvga    = false
    }
  }
}
