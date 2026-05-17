# Exports disk attachment metadata for each Longhorn-enabled node.
# Consumed by the talos module to attach the data VM's disk to the node VM
# via the (Experimental) path_in_datastore attribute.
output "disks" {
  description = "Disk attachment metadata keyed by node name. Only nodes with longhorn_disk_size > 0 are present."
  value = {
    for k, vm in proxmox_virtual_environment_vm.longhorn_data : k => {
      datastore_id      = vm.disk[0].datastore_id
      path_in_datastore = vm.disk[0].path_in_datastore
      file_format       = vm.disk[0].file_format
      size              = vm.disk[0].size
      # Serial is set on the data VM disk and must be carried through to the
      # node VM disk block so QEMU presents the device with the same serial
      # inside the guest, keeping the /dev/disk/by-id path stable.
      serial = vm.disk[0].serial
    }
  }
}
