#!/usr/bin/env bash
# ==============================================================================
# Utilitário de Conexão SSH via OCI Bastion Service
# Conecta com segurança às instâncias na Subnet Privada sem expor IPs públicos,
# utilizando OpenSSH ProxyCommand nativo (sem daemons locais ou conflitos de porta).
# ==============================================================================

set -euo pipefail

export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True

TARGET="${1:-}"

if [[ -z "${TARGET}" || "${TARGET}" == "-h" || "${TARGET}" == "--help" ]]; then
    echo "Uso: $0 <alvo> [comando_opcional...]"
    echo ""
    echo "Alvos disponíveis:"
    echo "  controlplane (ou cp) : Nó Control Plane do Kubernetes"
    echo "  worker               : Nó Worker do Kubernetes"
    echo "  vault                : Instância x86 HashiCorp Vault"
    echo "  vpn                  : Instância x86 VPN Management"
    echo ""
    echo "Exemplos:"
    echo "  $0 controlplane                     # Conexão interativa ao shell"
    echo "  $0 controlplane kubectl get nodes   # Executa comando remoto diretamente"
    echo "  $0 worker uptime                    # Executa comando no Worker"
    echo "  $0 vault                            # Conexão interativa ao Vault"
    echo "  $0 vpn                              # Conexão interativa à VPN"
    exit 0
fi

shift || true

SSH_KEY="${HOME}/.ssh/id_rsa"
SSH_PUB_KEY="${SSH_KEY}.pub"

if [[ ! -f "${SSH_KEY}" ]]; then
    echo "❌ Erro: Chave privada SSH não encontrada em ${SSH_KEY}"
    exit 1
fi

if [[ ! -f "${SSH_PUB_KEY}" ]]; then
    echo "❌ Erro: Chave pública SSH não encontrada em ${SSH_PUB_KEY}"
    exit 1
fi

if ! command -v terraform >/dev/null 2>&1; then
    echo "❌ Erro: terraform não está instalado no PATH."
    exit 1
fi

if ! command -v oci >/dev/null 2>&1; then
    echo "❌ Erro: oci CLI não está instalado no PATH."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "❌ Erro: jq não está instalado. Instale com: sudo apt-get install -y jq"
    exit 1
fi

# Diretório raiz do projeto Terraform
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "🔍 Consultando outputs do Terraform em ${ROOT_DIR}..."
BASTION_ID=$(terraform -chdir="${ROOT_DIR}" output -raw bastion_id 2>/dev/null || true)
if [[ -z "${BASTION_ID}" ]]; then
    echo "❌ Erro: Não foi possível obter o 'bastion_id' do Terraform. Verifique se executou 'terraform apply'."
    exit 1
fi

TARGET_IP=""
case "${TARGET}" in
    controlplane|cp)
        TARGET_IP=$(terraform -chdir="${ROOT_DIR}" output -raw k8s_control_plane_private_ip 2>/dev/null || true)
        ;;
    worker)
        TARGET_IP=$(terraform -chdir="${ROOT_DIR}" output -raw k8s_worker_private_ip 2>/dev/null || true)
        ;;
    vault)
        TARGET_IP=$(terraform -chdir="${ROOT_DIR}" output -raw vault_private_ip 2>/dev/null || true)
        ;;
    vpn)
        TARGET_IP=$(terraform -chdir="${ROOT_DIR}" output -raw vpn_private_ip 2>/dev/null || true)
        ;;
    *)
        echo "❌ Alvo inválido: ${TARGET}. Alvos suportados: controlplane, worker, vault, vpn."
        exit 1
        ;;
esac

if [[ -z "${TARGET_IP}" ]]; then
    echo "❌ Erro: Não foi possível obter o IP privado do alvo '${TARGET}'."
    exit 1
fi

echo "🎯 Alvo: ${TARGET} (${TARGET_IP})"

# 1. Verificar se já existe uma sessão ACTIVE para este IP no Bastion (Reuso rápido)
echo "🔍 Verificando sessões ativas no Bastion..."
ACTIVE_SESSIONS=$(oci bastion session list --bastion-id "${BASTION_ID}" --session-lifecycle-state ACTIVE 2>/dev/null || echo '{"data":[]}')
SESSION_ID=$(echo "${ACTIVE_SESSIONS}" | jq -r '.data[]? | select(."target-resource-details"."target-resource-private-ip-address" == "'"${TARGET_IP}"'") | .id' | head -n 1)

if [[ -n "${SESSION_ID}" && "${SESSION_ID}" != "null" ]]; then
    echo "⚡ Sessão ativa encontrada no Bastion: ${SESSION_ID} (Reaproveitando!)"
else
    # 2. Criar nova sessão de Port-Forwarding no Bastion
    SESSION_NAME="ssh-${TARGET}-$(date +%s)"
    echo "🚀 Criando nova sessão Port-Forwarding no Bastion..."
    SESSION_JSON=$(oci bastion session create-port-forwarding \
        --bastion-id "${BASTION_ID}" \
        --display-name "${SESSION_NAME}" \
        --ssh-public-key-file "${SSH_PUB_KEY}" \
        --target-private-ip "${TARGET_IP}" \
        --target-port 22 \
        --session-ttl 10800)

    SESSION_ID=$(echo "${SESSION_JSON}" | jq -r '.data.id')
    echo "✅ Sessão criada: ${SESSION_ID}"

    echo "⏳ Aguardando a sessão do Bastion ficar ativa..."
    while true; do
        CURRENT_STATE=$(oci bastion session get --session-id "${SESSION_ID}" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)
        if [[ "${CURRENT_STATE}" == "ACTIVE" ]]; then
            echo "✨ Sessão ativa!"
            break
        elif [[ "${CURRENT_STATE}" == "FAILED" || "${CURRENT_STATE}" == "DELETED" ]]; then
            echo "❌ Erro: A sessão do Bastion terminou com o estado: ${CURRENT_STATE}"
            exit 1
        fi
        sleep 2
    done
fi

# 3. Obter metadados SSH da sessão do Bastion
RAW_CMD=$(oci bastion session get --session-id "${SESSION_ID}" --query 'data."ssh-metadata".command' --raw-output 2>/dev/null || true)
if [[ -z "${RAW_CMD}" || "${RAW_CMD}" == "null" ]]; then
    echo "❌ Erro: Não foi possível obter o comando da sessão do Bastion."
    exit 1
fi

BASTION_USER_HOST=$(echo "${RAW_CMD}" | awk '{print $NF}')
if [[ -z "${BASTION_USER_HOST}" || "${BASTION_USER_HOST}" != *"@"* ]]; then
    echo "❌ Erro: Formato inesperado de host retornado pelo Bastion: ${RAW_CMD}"
    exit 1
fi

echo "🟢 Conectando com segurança via ProxyCommand..."

PROXY_CMD="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -W %h:%p -p 22 ${BASTION_USER_HOST}"

if [[ $# -gt 0 ]]; then
    echo "▶️ Executando comando remoto..."
    exec ssh -i "${SSH_KEY}" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ProxyCommand="${PROXY_CMD}" \
        "ubuntu@${TARGET_IP}" "$@"
else
    echo "✨ Sessão interativa iniciada em ${TARGET} (digite 'exit' para sair):"
    exec ssh -i "${SSH_KEY}" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ProxyCommand="${PROXY_CMD}" \
        "ubuntu@${TARGET_IP}"
fi
