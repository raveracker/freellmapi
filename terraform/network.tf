# VCN with a public subnet (load balancer) and a private subnet (app instance).
# The private instance reaches GHCR / providers outbound via the NAT gateway and
# is never directly reachable from the internet.

resource "oci_core_vcn" "vcn" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = ["10.0.0.0/16"]
  display_name   = "freellmapi-vcn"
  dns_label      = "freellmapi"
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "freellmapi-igw"
}

resource "oci_core_nat_gateway" "nat" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "freellmapi-nat"
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "freellmapi-rt-public"

  route_rules {
    network_entity_id = oci_core_internet_gateway.igw.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
  }
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "freellmapi-rt-private"

  route_rules {
    network_entity_id = oci_core_nat_gateway.nat.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
  }
}

resource "oci_core_subnet" "public" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.vcn.id
  cidr_block                 = "10.0.1.0/24"
  display_name               = "freellmapi-public"
  dns_label                  = "public"
  route_table_id             = oci_core_route_table.public.id
  prohibit_public_ip_on_vnic = false
}

resource "oci_core_subnet" "private" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.vcn.id
  cidr_block                 = "10.0.2.0/24"
  display_name               = "freellmapi-private"
  dns_label                  = "private"
  route_table_id             = oci_core_route_table.private.id
  prohibit_public_ip_on_vnic = true
}

# --- Network security groups ---------------------------------------------------

resource "oci_core_network_security_group" "lb" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "nsg-lb"
}

resource "oci_core_network_security_group" "app" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "nsg-app"
}

# LB: allow 443 inbound from the approved CIDRs.
resource "oci_core_network_security_group_security_rule" "lb_443" {
  for_each                  = toset(var.lb_ingress_cidrs)
  network_security_group_id = oci_core_network_security_group.lb.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = each.value
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

# LB: allow the bearer-only listener's port inbound from the approved CIDRs.
# Only created alongside the bearer listener (var.enable_bearer_listener).
resource "oci_core_network_security_group_security_rule" "lb_bearer" {
  for_each                  = var.enable_bearer_listener ? toset(var.lb_ingress_cidrs) : toset([])
  network_security_group_id = oci_core_network_security_group.lb.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = each.value
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = var.bearer_listener_port
      max = var.bearer_listener_port
    }
  }
}

# LB: allow egress to the app subnet on 3001 (health checks + proxying).
resource "oci_core_network_security_group_security_rule" "lb_egress_app" {
  network_security_group_id = oci_core_network_security_group.lb.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = oci_core_network_security_group.app.id
  destination_type          = "NETWORK_SECURITY_GROUP"

  tcp_options {
    destination_port_range {
      min = 3001
      max = 3001
    }
  }
}

# App: allow 3001 inbound ONLY from the load balancer NSG. No internet ingress.
resource "oci_core_network_security_group_security_rule" "app_3001" {
  network_security_group_id = oci_core_network_security_group.app.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.lb.id
  source_type               = "NETWORK_SECURITY_GROUP"

  tcp_options {
    destination_port_range {
      min = 3001
      max = 3001
    }
  }
}

# App: allow all egress (pull image from GHCR, reach LLM providers, Vault).
resource "oci_core_network_security_group_security_rule" "app_egress" {
  network_security_group_id = oci_core_network_security_group.app.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}

# SSH from the private subnet for OCI Bastion port-forwarding sessions.
resource "oci_core_network_security_group_security_rule" "app_ssh_bastion" {
  count                     = var.enable_bastion_ssh ? 1 : 0
  network_security_group_id = oci_core_network_security_group.app.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_subnet.private.cidr_block
  source_type               = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}
