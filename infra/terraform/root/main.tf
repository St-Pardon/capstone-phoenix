# Root module — wires network -> security -> compute. Run from infra/terraform/root/.
module "network" {
  source = "../modules/network"

  compartment_ocid = var.compartment_ocid
  name_prefix      = var.name_prefix
  vcn_cidr         = var.vcn_cidr
  subnet_cidr      = var.subnet_cidr
}

module "security" {
  source = "../modules/security"

  compartment_ocid = var.compartment_ocid
  name_prefix      = var.name_prefix
  vcn_id           = module.network.vcn_id
  vcn_cidr         = module.network.vcn_cidr
  allowed_ssh_cidr = var.allowed_ssh_cidr
}

module "compute" {
  source = "../modules/compute"

  compartment_ocid            = var.compartment_ocid
  name_prefix                 = var.name_prefix
  subnet_id                   = module.network.subnet_id
  nsg_id                      = module.security.nsg_id
  ssh_public_key_path         = var.ssh_public_key_path
  availability_domain_number  = var.availability_domain_number
  os_operating_system         = var.os_operating_system
  os_operating_system_version = var.os_operating_system_version

  server_shape     = var.server_shape
  server_ocpus     = var.server_ocpus
  server_memory_gb = var.server_memory_gb

  worker_shape     = var.worker_shape
  worker_count     = var.worker_count
  worker_ocpus     = var.worker_ocpus
  worker_memory_gb = var.worker_memory_gb

  boot_volume_gb = var.boot_volume_gb
}
