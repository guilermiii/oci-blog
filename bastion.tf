# ==============================================================================
# OCI Bastion Service Gerenciado (Always Free)
# Permite acesso SSH a instâncias em subnets privadas sem expor IPs públicos
# ==============================================================================

resource "oci_bastion_bastion" "bastion" {
  bastion_type     = "STANDARD"
  compartment_id   = var.compartment_ocid
  target_subnet_id = oci_core_subnet.private_subnet.id
  name             = "bastion-always-free"

  client_cidr_block_allow_list = var.bastion_client_cidr_block_allow_list
  max_session_ttl_in_seconds   = 10800 # 3 horas (tempo máximo permitido)

  freeform_tags = {
    "Project" = "BastionService"
  }
}
