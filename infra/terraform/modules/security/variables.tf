variable "compartment_ocid" {
  description = "OCID of the compartment to create the NSG in."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource display names."
  type        = string
}

variable "vcn_id" {
  description = "OCID of the VCN the NSG belongs to (from the network module)."
  type        = string
}

variable "vcn_cidr" {
  description = "VCN CIDR — source for intra-cluster (node-to-node) rules."
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to reach SSH (22) and the k3s API (6443). Your IP /32, never 0.0.0.0/0."
  type        = string
}
