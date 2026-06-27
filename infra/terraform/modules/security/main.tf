# Single NSG attached to every node VNIC (in the compute module). OCI protocol numbers:
# "6" = TCP, "17" = UDP, "all" = all protocols.
resource "oci_core_network_security_group" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = var.vcn_id
  display_name   = "${var.name_prefix}-nodes-nsg"
}

locals {
  # Least-privilege ingress. Only 80/443 face the world; 22/6443 are operator-only; the
  # k3s-documented inter-node ports (6443, 8472/udp, 10250) are scoped to the VCN.
  nsg_ingress = {
    ssh = {
      description = "SSH from operator IP"
      protocol    = "6"
      source      = var.allowed_ssh_cidr
      port        = 22
    }
    kube_api_operator = {
      description = "k3s API from operator IP (laptop kubectl)"
      protocol    = "6"
      source      = var.allowed_ssh_cidr
      port        = 6443
    }
    http = {
      description = "HTTP from internet (ingress + ACME HTTP-01)"
      protocol    = "6"
      source      = "0.0.0.0/0"
      port        = 80
    }
    https = {
      description = "HTTPS from internet (ingress)"
      protocol    = "6"
      source      = "0.0.0.0/0"
      port        = 443
    }
    kube_api_nodes = {
      description = "k3s API from inside the VCN (agent join)"
      protocol    = "6"
      source      = var.vcn_cidr
      port        = 6443
    }
    flannel_vxlan = {
      description = "flannel VXLAN between nodes"
      protocol    = "17"
      source      = var.vcn_cidr
      port        = 8472
    }
    kubelet = {
      description = "kubelet / metrics-server between nodes"
      protocol    = "6"
      source      = var.vcn_cidr
      port        = 10250
    }
  }
}

resource "oci_core_network_security_group_security_rule" "ingress" {
  for_each = local.nsg_ingress

  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "INGRESS"
  protocol                  = each.value.protocol
  source                    = each.value.source
  source_type               = "CIDR_BLOCK"
  description               = each.value.description

  dynamic "tcp_options" {
    for_each = each.value.protocol == "6" ? [1] : []
    content {
      destination_port_range {
        min = each.value.port
        max = each.value.port
      }
    }
  }

  dynamic "udp_options" {
    for_each = each.value.protocol == "17" ? [1] : []
    content {
      destination_port_range {
        min = each.value.port
        max = each.value.port
      }
    }
  }
}

# Nodes need outbound for image pulls (GHCR), the k3s installer, and Let's Encrypt.
resource "oci_core_network_security_group_security_rule" "egress_all" {
  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Allow all egress (image pulls, k3s install, ACME)."
}
