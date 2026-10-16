# Infraestrutura OCI Always Free com Terraform

Projeto modular em Terraform para provisionamento de infraestrutura 100% elegível ao tier **Always Free** da Oracle Cloud Infrastructure (OCI).

## 🚀 Arquitetura e Recursos

- **Cluster Kubernetes (ARM Ampere A1)**:
  - 2 instâncias `VM.Standard.A1.Flex` (2 OCPUs e 12 GB de RAM cada = total de 4 OCPUs e 24 GB de RAM).
  - Boot volume de 50 GB cada máquina.
  - Tag: `Project:Blog-do-Zeca`.
  - Automação completa via Cloud-Init/Userdata com `containerd`, `kubeadm`, `kubelet`, `kubectl` e CNI Flannel.
- **Instâncias x86 (Micro)**:
  - 2 instâncias `VM.Standard.E2.1.Micro` (1 OCPU e 1 GB de RAM cada).
  - Boot volume de 50 GB cada máquina.
  - Instância 1 com tag: `Project:vault`.
  - Instância 2 com tag: `Project:VpnManagement`.
  - Scripts templates de inicialização via Userdata.
- **Armazenamento**:
  - 4 instâncias x 50 GB = **200 GB no total**, exatamente a cota máxima gratuita do OCI Always Free.
- **Rede e Isolamento**:
  - **Subnet Pública (`10.0.1.0/24`)**: Contém exclusivamente o Load Balancer e o IP Público Reservado.
  - **Subnet Privada (`10.0.2.0/24`)**: Abriga todas as 4 instâncias (ARM e x86) com `assign_public_ip = false`.
  - **NAT Gateway**: Fornece saída segura para a internet (permitindo `apt-get` e download de pacotes/imagens durante o userdata) com zero exposição de portas para a internet pública nas instâncias x86.
- **Load Balancer**:
  - 1 Load Balancer Flexível de 10 Mbps (Always Free).
  - 1 **IP Público Fixo Reservado** (`oci_core_public_ip` com `lifetime = "RESERVED"`).
  - Roteamento e health checks configurados para encaminhar tráfego web ao cluster.
- **Backend Remoto Nativo OCI**:
  - Utilização do backend nativo oficial `backend "oci"` apontando para o bucket `tf-state-lock-blog` (namespace `gr2g4g6jibse`, região `sa-saopaulo-1`).
  - Estado armazenado na raiz (`terraform.tfstate`) com bloqueio de estado (*state locking*) nativo.
- **Segurança de Credenciais**:
  - Nenhuma credencial hardcoded. Lê a configuração e a chave `.pem` do perfil `~/.oci/config` (perfil `DEFAULT`).
  - Chave SSH referenciada por caminho de arquivo (`ssh_public_key_path`).

---

## 📁 Estrutura de Diretórios

```text
oci-blog/
├── .gitignore
├── README.md
├── backend.tf              # Backend NATIVO da OCI (backend "oci") no bucket tf-state-zekinhas
├── bastion.tf              # OCI Bastion Service gerenciado (Always Free) para acesso SSH privado
├── datasources.tf          # Descoberta AUTOMÁTICA de Availability Domain e Imagens Ubuntu 24.04 LTS
├── provider.tf             # Provedor OCI configurado com ~/.oci/config (perfil DEFAULT)
├── variables.tf            # Apenas declaração de variáveis de entrada (SEM NENHUM DEFAULT)
├── terraform.tfvars        # Valores das variáveis (ignorado no Git)
├── terraform.tfvars.example# Modelo de exemplo seguro para versionamento
├── network.tf              # VCN, Internet Gateway, NAT Gateway, Route Tables e Subnets (Pública e Privada)
├── main.tf                 # Orquestração chamando blog_do_zeca e x86
├── outputs.tf              # Saídas de IPs, Load Balancer, Imagens descobertas, Bastion e instruções
│
├── scripts/
│   └── ssh-connect.sh      # Script utilitário para conexão SSH automática via OCI Bastion
│
├── blog_do_zeca/           # TUDO RELACIONADO AO KUBERNETES
│   ├── main.tf             # Ponto de entrada do módulo K8s
│   ├── compute.tf          # 2x instâncias ARM A1 Flex (50 GB boot cada, Tag Project: Blog-do-Zeca)
│   ├── load_balancer.tf    # IP Público Fixo Reservado + Load Balancer Flexível 10 Mbps + Backend Set + Listener
│   ├── security.tf         # Regras de segurança K8s (6443, 10250, Flannel 8472 UDP, NodePorts, Ingress do LB)
│   ├── variables.tf        # Variáveis do módulo K8s (SEM NENHUM DEFAULT)
│   ├── outputs.tf          # IP do LB, IPs privados do Control Plane e Worker
│   └── cli/
│       ├── controlplane.sh # Script bash: containerd, kubeadm init, CNI Flannel, geração de token join
│       └── worker.sh       # Script bash: containerd, kubeadm, kubelet, preparação para join
│
└── x86/                    # TUDO RELACIONADO ÀS MÁQUINAS x86
    ├── main.tf             # Ponto de entrada do módulo x86
    ├── compute.tf          # 2x instâncias E2.1.Micro (50 GB boot cada, Tags Project: vault e Project: VpnManagement)
    ├── security.tf         # Regras de segurança x86 (Subnet privada, ZERO tráfego de entrada público)
    ├── variables.tf        # Variáveis do módulo x86 (SEM NENHUM DEFAULT)
    ├── outputs.tf          # IPs privados do Vault e VPN
    ├── cli/
    │   ├── vault.sh        # Script bash template para inicialização do Vault
    │   └── vpn.sh          # Script bash template para inicialização da VPN
    └── manifests/
        └── README.md       # Documentação para futuros manifestos e configs x86
```

---

## 🛠️ Pré-requisitos

1. **OCI CLI**: Instalado via pip e configurado com suas credenciais e chave `.pem`:
   ```bash
   oci setup config
   ```
2. **Terraform**: Versão `>= 1.5.0` instalada.
3. **Chave SSH**: Gerada em `~/.ssh/id_rsa.pub` (ou caminho equivalente).

---

## 🔍 Descoberta Automática de Recursos (Zero Consultas Manuais)

Graças ao arquivo [`datasources.tf`](file:///home/guilermiii/github/oci-blog/datasources.tf), o Terraform consulta a API da OCI automaticamente para:
- Selecionar o **Availability Domain** adequado na sua região.
- Localizar a imagem oficial mais recente do **Ubuntu 24.04 LTS (ARM aarch64)** para as instâncias do Kubernetes.
- Localizar a imagem oficial mais recente do **Ubuntu 24.04 LTS (x86_64)** para as instâncias do Vault e VPN.

Você **não precisa** buscar OCIDs de imagens nem nomes de domínios manualmente! Basta definir o seu `compartment_ocid` no [`terraform.tfvars`](file:///home/guilermiii/github/oci-blog/terraform.tfvars).

> 💡 **Como saber seu Compartment OCID**:
> Se você utiliza a raiz da conta (Root Tenancy), consulte com:
> ```bash
> grep "tenancy" ~/.oci/config
> ```

---

## ⚡ Como Inicializar e Aplicar

1. **Preencha o arquivo `terraform.tfvars`**:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   # Edite os valores com seus OCIDs reais
   ```

2. **Inicialize o Terraform com o Backend Nativo da OCI**:
   ```bash
   terraform init
   ```

3. **Verifique o plano de execução**:
   ```bash
   terraform plan
   ```

4. **Aplique o provisionamento**:
   ```bash
   terraform apply
   ```

---

## ☸️ Conectando o Cluster Kubernetes

1. O nó **Control Plane** inicializa automaticamente o cluster e salva o comando de join em:
   ```bash
   /home/ubuntu/kubeadm-join.sh
   ```

2. Para conectar o nó **Worker**:
   - Conecte via SSH no Control Plane e copie o conteúdo de `/home/ubuntu/kubeadm-join.sh`.
   - Conecte via SSH no Worker e execute o comando com `sudo`.

3. Verifique o status dos nós no Control Plane:
   ```bash
   kubectl get nodes -o wide
   kubectl get pods -A
   ```

---

## 🔐 Acesso SSH Seguro às Instâncias Privadas (via OCI Bastion)

Todas as instâncias residem na Subnet Privada sem IPs públicos diretos. Para conectar de forma simples e segura, utilize o script auxiliar [`scripts/ssh-connect.sh`](file:///home/guilermiii/github/oci-blog/scripts/ssh-connect.sh):

```bash
# Conectar ao nó Control Plane do Kubernetes:
./scripts/ssh-connect.sh controlplane

# Conectar ao nó Worker do Kubernetes:
./scripts/ssh-connect.sh worker

# Conectar à instância x86 Vault:
./scripts/ssh-connect.sh vault

# Conectar à instância x86 VPN:
./scripts/ssh-connect.sh vpn
```

O script consulta os outputs do Terraform, cria a sessão de port-forwarding no OCI Bastion sob demanda e estabelece o túnel SSH diretamente para a máquina desejada.
