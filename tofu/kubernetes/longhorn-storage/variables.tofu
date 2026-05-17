variable "nodes" {
  description = "Kubernetes node configuration. Only nodes with longhorn_disk_size > 0 get a data holder VM."
  type = map(object({
    host_node          = string
    vm_id              = number
    datastore_id       = optional(string, "local-lvm")
    longhorn_disk_size = optional(number, 0)
  }))
}
