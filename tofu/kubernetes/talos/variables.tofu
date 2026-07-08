variable "cluster" {
  description = "Cluster configuration"
  type = object({
    name                         = string
    vip                          = optional(string)
    gateway                      = string
    subnet_mask                  = optional(string, "24")
    talos_machine_config_version = optional(string)
    proxmox_cluster              = string
    kubernetes_version           = string
    gateway_api_version          = string
    extra_manifests              = optional(list(string))
    kubelet                      = optional(string)
    api_server                   = optional(string)
  })
}

variable "nodes" {
  description = "Configuration for cluster nodes"
  type = map(object({
    host_node     = string
    machine_type  = string
    datastore_id  = optional(string, "local-lvm")
    ip            = string
    vlan_id       = optional(number)
    mac_address   = string
    vm_id         = number
    cpu           = number
    ram_dedicated = number
    update        = optional(bool, false)
    igpu          = optional(bool, false)
    # Size in GB of the dedicated data disk (scsi1).
    # Set to 0 (default) to skip disk creation for nodes without data storage.
    data_disk_size = optional(number, 0)
  }))
  validation {
    condition     = alltrue([for n in values(var.nodes) : n.data_disk_size >= 0])
    error_message = "Node data_disk_size must be greater than or equal to 0."
  }
}

variable "image" {
  description = "Talos image configuration"
  type = object({
    factory_url           = optional(string, "https://factory.talos.dev")
    version               = string
    schematic_path        = string
    update_version        = optional(string)
    update_schematic_path = optional(string)
    arch                  = optional(string, "amd64")
    platform              = optional(string, "nocloud")
    proxmox_datastore     = optional(string, "local")
  })
}
