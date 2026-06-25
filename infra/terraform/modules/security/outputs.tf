output "nsg_id" {
  description = "OCID of the node NSG — attach to instance VNICs in the compute module."
  value       = oci_core_network_security_group.this.id
}
