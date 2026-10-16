#!/usr/bin/env bash
# ==============================================================================
# Utilitário de Conexão SSH via OCI Bastion Service
# Conecta com segurança às instâncias na Subnet Privada sem IP público.
# ==============================================================================

set -euo pipefail

TARGET="${1:-}"

if [[ -z "${TARGET}" || "${TARGET}" == "-h" || "${TARGET}" == "--help" ]]; then
    echo "Uso: $0 <alvo> [caminho_chave_ssh]"
    echo ""
    echo "Alvos disponíveis:"
    echo "  controlplane (ou cp) : Nó Control Plane do Kubernetes"
    echo "  worker               : Nó Worker do Kubernetes"
    echo "  vault                : Instância x86 HashiCorp Vault"
    echo "  vpn                  : Instância x86 VPN Management"
    echo ""
    echo "Exemplo:"
    echo "  $0 controlplane"
    echo "  $0 worker ~/.ssh/id_rsa"
    exit 0
fi

SSH_KEY="${2:-${HOME}/.ssh/id_rsa}"
SSH_PUB_KEY="${SSH_KEY}.pub"

if [[ ! -f "${SSH_KEY}" ]]; then
    echo "❌ Erro: Chave privada SSH não encontrada em ${SSH_KEY}"
    exit 1
fi

if [[ ! -f "${SSH_PUB_KEY}" ]]; then
    echo "❌ Erro: Chave pública SSH não encontrada em ${SSH_PUB_KEY}"
    exit 1
fi

echo "🔍 Consultando outputs do Terraform..."
if ! command -v terraform >/dev/null 2>&1; then
    echo "❌ Erro: terraform não está instalado no PATH."
    exit 1
fi

if ! command -v oci >/dev/null 2>&1; then
    echo "❌ Erro: oci CLI não está instalado no PATH."
    exit 1
fi

BASTION_ID=$(terraform output -raw bastion_id 2>/dev/null || true)
if [[ -z "${BASTION_ID}" ]]; then
    echo "❌ Erro: Não foi possível obter o 'bastion_id' do Terraform. Verifique se executou 'terraform apply'."
    exit 1
fi

TARGET_IP=""
case "${TARGET}" in
    controlplane|cp)
        TARGET_IP=$(terraform output -raw k8s_control_plane_private_ip 2>/dev/null || true)
        ;;
    worker)
        TARGET_IP=$(terraform output -raw k8s_worker_private_ip 2>/dev/null || true)
        ;;
    vault)
        TARGET_IP=$(terraform output -raw vault_private_ip 2>/dev/null || true)
        ;;
    vpn)
        TARGET_IP=$(terraform output -raw vpn_private_ip 2>/dev/null || true)
        ;;
    *)
        echo "❌ Alvo inválido: ${TARGET}. Use: controlplane, worker, vault ou vpn."
        exit 1
        ;;
esac

if [[ -z "${TARGET_IP}" ]]; then
    echo "❌ Erro: Não foi possível obter o IP privado do alvo '${TARGET}'."
    exit 1
fi

LOCAL_PORT=$(( (RANDOM % 1000) + 2200 ))
SESSION_NAME="bastion-session-${TARGET}-$(date +%s)"

echo "🚀 Criando sessão Port-Forwarding no OCI Bastion para ${TARGET} (${TARGET_IP}:22)..."
SESSION_JSON=$(oci bastion session create-port-forwarding \
    --bastion-id "${BASTION_ID}" \
    --display-name "${SESSION_NAME}" \
    --ssh-public-key-file "${SSH_PUB_KEY}" \
    --target-private-ip "${TARGET_IP}" \
    --target-port 22 \
    --session-ttl 10800 \
    --output json)

SESSION_ID=$(echo "${SESSION_JSON}" | jq -r '.data.id')
echo "✅ Sessão criada com sucesso: ${SESSION_ID}"

echo "⏳ Aguardando a sessão do Bastion ficar ativa..."
oci bastion session get --session-id "${SESSION_ID}" --wait-for-state ACTIVE >/dev/null

BASTION_HOST=$(oci bastion bastion get --bastion-id "${BASTION_ID}" --query 'data."bastion-type"' --output text 2>/dev/null || true)
REGION=$(oci bastion bastion get --bastion-id "${BASTION_ID}" --query 'data.id' --output text | cut -d'.' -f4)
BASTION_ENDPOINT="host.bastion.${REGION}.oci.oraclecloud.com"

echo "🔗 Estabelecendo túnel SSH local na porta ${LOCAL_PORT}..."
ssh -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/dev/null \
    -i "${SSH_KEY}" \
    -N -L "${LOCAL_PORT}:${TARGET_IP}:22" \
    -p 22 "${SESSION_ID}@${BASTION_ENDPOINT}" &
TUNNEL_PID=$!

# Função para encerrar o túnel local ao sair do SSH
cleanup() {
    echo ""
    echo "🛑 Encerrando túnel local do Bastion (PID: ${TUNNEL_PID})..."
    kill "${TUNNEL_PID}" 2>/dev/null || true
}
trap cleanup EXIT

# Aguardar inicialização do socket local
sleep 3

echo "✨ Conectando ao host ${TARGET} (ubuntu@127.0.0.1:${LOCAL_PORT})..."
ssh -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/dev/null \
    -i "${SSH_KEY}" \
    -p "${LOCAL_PORT}" \
    ubuntu@127.0.0.1
