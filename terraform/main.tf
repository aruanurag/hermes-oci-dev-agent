resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.name_prefix}-vcn"
  cidr_block     = "10.42.0.0/16"
  dns_label      = "hermes"
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-igw"
  enabled        = true
}

resource "oci_core_nat_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-nat"
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-private-rt"
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.this.id
  }
}

resource "oci_core_security_list" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-private-sl"
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }
}

resource "oci_core_subnet" "private" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  display_name               = "${var.name_prefix}-private-subnet"
  cidr_block                 = "10.42.1.0/24"
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private.id]
  prohibit_public_ip_on_vnic = true
  dns_label                  = "private"
}

resource "oci_core_network_security_group" "compute" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-compute-nsg"
}

# OCI Bastion is the only permitted inbound path. The Dashboard listens on the
# private VNIC solely so a time-limited Bastion port-forwarding session can
# reach it; it has no public IP or public ingress rule.
resource "oci_core_network_security_group_security_rule" "bastion_ssh" {
  network_security_group_id = oci_core_network_security_group.compute.id
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

resource "oci_core_network_security_group_security_rule" "bastion_dashboard" {
  network_security_group_id = oci_core_network_security_group.compute.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_subnet.private.cidr_block
  source_type               = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      min = 9119
      max = 9119
    }
  }
}

resource "oci_bastion_bastion" "this" {
  bastion_type                 = "STANDARD"
  compartment_id               = var.compartment_ocid
  target_subnet_id             = oci_core_subnet.private.id
  client_cidr_block_allow_list = [var.bastion_client_cidr]
  name                         = "${var.name_prefix}-bastion"
  max_session_ttl_in_seconds   = 10800
}

resource "oci_core_instance" "hermes" {
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  display_name        = "${var.name_prefix}-compute"
  shape               = var.instance_shape

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gbs
  }

  agent_config {
    are_all_plugins_disabled = false
    plugins_config {
      name          = "Bastion"
      desired_state = "ENABLED"
    }
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.private.id
    assign_public_ip = false
    nsg_ids          = [oci_core_network_security_group.compute.id]
  }

  source_details {
    source_type             = "image"
    source_id               = var.compute_image_ocid
    boot_volume_size_in_gbs = var.boot_volume_size_gbs
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
      region             = var.region
      compartment_ocid   = var.compartment_ocid
      genai_project_ocid = var.genai_project_ocid
      genai_model_id     = var.genai_model_id
      ssh_public_key     = var.ssh_public_key
      proxy_server       = filebase64("${path.module}/../docker/oci-genai-proxy/server.py")
      proxy_verify       = filebase64("${path.module}/../docker/oci-genai-proxy/verify.py")
      hermes_config = base64encode(templatefile("${path.module}/../installer-config.yaml.tftpl", {
        genai_model_id = var.genai_model_id
      }))
    }))
  }
}

resource "oci_identity_dynamic_group" "hermes" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${var.name_prefix}-compute-dg"
  description    = "Only the Hermes Compute instance may invoke OCI Generative AI."
  matching_rule  = "ALL {instance.id = '${oci_core_instance.hermes.id}'}"
}

resource "oci_identity_policy" "hermes_genai" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = "${var.name_prefix}-genai-inference"
  description    = "Allow Hermes instance principal to invoke OCI Generative AI chat in one compartment."
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.hermes.name} to use generative-ai-chat in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.hermes.name} to use generative-ai-response in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.hermes.name} to use generative-ai-project in compartment id ${var.compartment_ocid}"
  ]
}
