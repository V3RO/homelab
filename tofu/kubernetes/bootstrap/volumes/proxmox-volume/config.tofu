locals {
  filename = "vm-${var.volume.vmid}-${var.volume.name}"

  # Convert Kubernetes binary size notation (e.g. 2Gi) to Proxmox size notation (e.g. 2048M).
  # Proxmox uses M (mebibytes) natively, so converting Gi -> M avoids any mismatch
  # between Gi (2^30) and G (10^9) that would cause PVC binding failures.
  size_number = tonumber(regex("^([0-9]+)", var.volume.size)[0])
  size_suffix = regex("[0-9]+(.+)$", var.volume.size)[0]
  proxmox_size = (
    local.size_suffix == "Gi" ? "${local.size_number * 1024}M" :
    local.size_suffix == "Ti" ? "${local.size_number * 1024}G" :
    local.size_suffix == "Mi" ? "${local.size_number}M" :
    var.volume.size
  )
}

resource "restapi_object" "proxmox-volume" {
  count = var.volume.existing ? 0 : 1
  path  = "/api2/json/nodes/${var.volume.node}/storage/${var.volume.storage}/content"

  id_attribute = "data"

  debug = true

  data = jsonencode({
    vmid     = var.volume.vmid
    filename = local.filename
    size     = local.proxmox_size
    format   = var.volume.format
  })

  // Proxmox returns a different object which we ignore.
  // The size is also returned in bytes, not with prefix, e.g. 1G, 512Mi.
  // Setting to false (default) triggers a change each run
  ignore_all_server_changes = true

  // Providing a supported parameter that doesn't do anything.
  // Supplying either `null` or an empty object makes this fall back to the `data` object.
  update_data = jsonencode({
    node = var.volume.node
  })

  lifecycle {
    prevent_destroy = false
  }
}

output "node" {
  value = var.volume.node
}

output "storage" {
  value = var.volume.storage
}

output "filename" {
  value = local.filename
}
