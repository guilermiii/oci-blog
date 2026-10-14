# ==============================================================================
# Data Sources: Descoberta Automática de Recursos da Região (OCI Always Free)
# ==============================================================================

# Consulta os Availability Domains disponíveis na região informada
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_ocid
}

# Consulta a imagem oficial mais recente do Ubuntu 24.04 LTS para ARM (Ampere A1 Flex)
data "oci_core_images" "ubuntu_arm" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# Consulta a imagem oficial mais recente do Ubuntu 24.04 LTS para x86 (Micro E2.1)
data "oci_core_images" "ubuntu_x86" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.E2.1.Micro"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}
