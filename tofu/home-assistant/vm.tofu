resource "proxmox_virtual_environment_vm" "home_assistant" {
  node_name = var.proxmox_cluster.name

  name          = "Home-Assistant"
  on_boot       = true
  bios          = "ovmf"
  scsi_hardware = "virtio-scsi-single"

  vm_id = 410

  tablet_device = false

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 4096
  }

  network_device {
    bridge      = "vmbr0"
    mac_address = "BC:24:11:2E:C8:00"
    vlan_id = 40
  }

  initialization {
    ip_config {
      ipv4 {
        address = "10.1.40.10/24"
        gateway = "10.1.40.1"
      }
    }
  }

  agent {
    enabled = true
  }

  efi_disk {
    datastore_id = "local-lvm"
    file_format  = "raw"
    type         = "4m"
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_file.haos_generic_image.id
    interface    = "scsi0"
    cache        = "writethrough"
    discard      = "on"
    iothread     = true
    ssd          = true
    size         = 64
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    prevent_destroy = false
  }
}
