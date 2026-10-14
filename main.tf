# Orquestração Principal da Infraestrutura OCI Always Free

# Módulo 1: Cluster Kubernetes ARM (Blog do Zeca) + Load Balancer Flexível com IP Fixo Reservado
module "blog_do_zeca" {
  source = "./blog_do_zeca"

  compartment_ocid         = var.compartment_ocid
  availability_domain_name = var.availability_domain_name
  subnet_id                = oci_core_subnet.private_subnet.id
  public_subnet_id         = oci_core_subnet.public_subnet.id
  ubuntu_arm_image_ocid    = var.ubuntu_arm_image_ocid
  ssh_public_key_path      = var.ssh_public_key_path
  tag_project              = var.tag_project_arm
  arm_ocpus                = 2
  arm_memory_in_gbs        = 12
  boot_volume_size_in_gbs  = 50
}

# Módulo 2: Instâncias x86 Micro (Vault & VPN Management) em Subnet Privada
module "x86" {
  source = "./x86"

  compartment_ocid         = var.compartment_ocid
  availability_domain_name = var.availability_domain_name
  subnet_id                = oci_core_subnet.private_subnet.id
  ubuntu_x86_image_ocid    = var.ubuntu_x86_image_ocid
  ssh_public_key_path      = var.ssh_public_key_path
  tag_vault                = var.tag_project_vault
  tag_vpn                  = var.tag_project_vpn
  boot_volume_size_in_gbs  = 50
}
