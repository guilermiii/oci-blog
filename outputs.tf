output "load_balancer_public_ip" {
  value       = module.blog_do_zeca.load_balancer_public_ip
  description = "IP Público Fixo Reservado do Load Balancer (Blog do Zeca)"
}

output "k8s_control_plane_private_ip" {
  value       = module.blog_do_zeca.control_plane_private_ip
  description = "IP Privado do nó Control Plane do Kubernetes"
}

output "k8s_worker_private_ip" {
  value       = module.blog_do_zeca.worker_private_ip
  description = "IP Privado do nó Worker do Kubernetes"
}

output "vault_private_ip" {
  value       = module.x86.vault_private_ip
  description = "IP Privado da instância x86 Vault"
}

output "vpn_private_ip" {
  value       = module.x86.vpn_private_ip
  description = "IP Privado da instância x86 VPN Management"
}

output "k8s_join_instruction" {
  value       = "Acesse o nó Control Plane para obter o comando gerado em /home/ubuntu/kubeadm-join.sh e execute-o no Worker."
  description = "Instrução para conectar o worker ao cluster Kubernetes"
}
