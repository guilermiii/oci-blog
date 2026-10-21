#!/usr/bin/env bash
# ==============================================================================
# Utilitário de Conexão SSH via OCI Bastion Service
# Conecta com segurança às instâncias na Subnet Privada sem expor IPs públicos,
# utilizando OpenSSH ProxyCommand nativo (sem daemons locais ou conflitos de porta).
# ==============================================================================

set -euo pipefail

export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True

# Configuração da chave SSH padrão (pode ser sobrescrita via OCI_SSH_KEY ou flag -i)
SSH_KEY="${OCI_SSH_KEY:-${HOME}/.ssh/id_rsa}"

# Processar argumentos da linha de comando
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--identity)
            if [[ -n "${2:-}" ]]; then
                SSH_KEY="$2"
                shift 2
            else
                echo "❌ Erro: Flag '$1' requer o caminho do arquivo de chave privada."
                exit 1
            fi
            ;;
        -h|--help)
            echo "Uso: $0 [-i caminho_chave] <alvo> [comando_opcional...]"
            echo ""
            echo "Alvos disponíveis:"
            echo "  controlplane (ou cp) : Nó Control Plane do Kubernetes"
            echo "  worker               : Nó Worker do Kubernetes"
            echo "  vault                : Instância x86 HashiCorp Vault"
            echo "  vpn                  : Instância x86 VPN Management"
            echo ""
            echo "Opções:"
            echo "  -i, --identity <path> : Especifica caminho da chave privada SSH (padrão: ~/.ssh/id_rsa ou \$OCI_SSH_KEY)"
            echo "  -h, --help            : Exibe esta ajuda"
            echo ""
            echo "Exemplos:"
            echo "  $0 controlplane                     # Conexão interativa ao shell"
            echo "  $0 controlplane kubectl get nodes   # Executa comando remoto diretamente"
            echo "  $0 worker uptime                    # Executa comando no Worker"
            echo "  $0 -i ~/.ssh/minha_chave vault      # Conexão especificando chave customizada"
            echo "  $0 vpn                              # Conexão interativa à VPN"
            exit 0
            ;;
        *)
            break
            ;;
    esac
done

TARGET="${1:-}"

if [[ -z "${TARGET}" ]]; then
    echo "❌ Erro: Nenhum alvo especificado."
    echo "Execute '$0 --help' para ver os comandos e opções disponíveis."
    exit 1
fi

shift || true

SSH_PUB_KEY="${SSH_KEY}.pub"

if [[ ! -f "${SSH_KEY}" ]]; then
    echo "❌ Erro: Chave privada SSH não encontrada em ${SSH_KEY}"
    exit 1
fi

if [[ ! -f "${SSH_PUB_KEY}" ]]; then
    echo "❌ Erro: Chave pública SSH não encontrada em ${SSH_PUB_KEY}"
    exit 1
fi

# Ajustar permissões da chave privada para 600 de forma defensiva
chmod 600 "${SSH_KEY}" 2>/dev/null || true

# Validar ferramentas essenciais no PATH
for cmd in terraform oci jq ssh; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "❌ Erro: Comando '${cmd}' não está instalado ou não está no PATH."
        exit 1
    fi
done

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

# Obter token normalizado da chave pública local (tipo e base64) para comparação
LOCAL_PUB_TOKEN=$(awk '{print $1, $2}' "${SSH_PUB_KEY}")

# Função para criar uma nova sessão no Bastion
create_bastion_session() {
    local target_ip="$1"
    local session_name="ssh-${TARGET}-$(date +%s)"
    echo "🚀 Criando nova sessão Port-Forwarding no Bastion..." >&2
    local session_json
    session_json=$(oci bastion session create-port-forwarding \
        --bastion-id "${BASTION_ID}" \
        --display-name "${session_name}" \
        --ssh-public-key-file "${SSH_PUB_KEY}" \
        --target-private-ip "${target_ip}" \
        --target-port 22 \
        --session-ttl 10800)

    local new_id
    new_id=$(echo "${session_json}" | jq -r '.data.id')
    echo "✅ Sessão criada: ${new_id}" >&2

    echo "⏳ Aguardando a sessão do Bastion ficar ativa..." >&2
    while true; do
        local state
        state=$(oci bastion session get --session-id "${new_id}" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)
        if [[ "${state}" == "ACTIVE" ]]; then
            echo "✨ Sessão ativa!" >&2
            break
        elif [[ "${state}" == "FAILED" || "${state}" == "DELETED" ]]; then
            echo "❌ Erro: A sessão do Bastion terminou com o estado: ${state}" >&2
            exit 1
        fi
        sleep 2
    done

    # Pausa de estabilização pós-ativação: necessária para propagação da chave nos daemons do Bastion
    echo "⏳ Aguardando sincronização da chave SSH no cluster do Bastion (5s)..." >&2
    sleep 5

    echo "${new_id}"
}

# 1. Verificar se já existe uma sessão ACTIVE compatível para este IP no Bastion
echo "🔍 Verificando sessões ativas no Bastion..."
ACTIVE_SESSIONS=$(oci bastion session list --bastion-id "${BASTION_ID}" --session-lifecycle-state ACTIVE 2>/dev/null || echo '{"data":[]}')
MATCHING_SESSION_IDS=$(echo "${ACTIVE_SESSIONS}" | jq -r '.data[]? | select(."target-resource-details"."target-resource-private-ip-address" == "'"${TARGET_IP}"'") | .id')

SESSION_ID=""
IS_REUSED_SESSION=0

for cand_id in ${MATCHING_SESSION_IDS}; do
    SESSION_PUB=$(oci bastion session get --session-id "${cand_id}" --query 'data."key-details"."public-key-content"' --raw-output 2>/dev/null || true)
    SESSION_PUB_TOKEN=$(echo "${SESSION_PUB}" | awk '{print $1, $2}')
    if [[ -n "${SESSION_PUB_TOKEN}" && "${SESSION_PUB_TOKEN}" == "${LOCAL_PUB_TOKEN}" ]]; then
        SESSION_ID="${cand_id}"
        IS_REUSED_SESSION=1
        echo "⚡ Sessão ativa compatível encontrada no Bastion: ${SESSION_ID} (Reaproveitando!)"
        break
    fi
done

if [[ -z "${SESSION_ID}" ]]; then
    SESSION_ID=$(create_bastion_session "${TARGET_IP}")
    IS_REUSED_SESSION=0
fi

# Função para resolver o host do Bastion
get_bastion_host() {
    local sess_id="$1"
    local raw_cmd
    raw_cmd=$(oci bastion session get --session-id "${sess_id}" --query 'data."ssh-metadata".command' --raw-output 2>/dev/null || true)
    if [[ -z "${raw_cmd}" || "${raw_cmd}" == "null" ]]; then
        echo ""
        return
    fi
    echo "${raw_cmd}" | awk '{print $NF}'
}

BASTION_USER_HOST=$(get_bastion_host "${SESSION_ID}")
if [[ -z "${BASTION_USER_HOST}" || "${BASTION_USER_HOST}" != *"@"* ]]; then
    echo "❌ Erro: Formato inesperado de host retornado pelo Bastion."
    exit 1
fi

echo "🟢 Configurando túnel seguro com ProxyCommand..."

# Construir comandos com opções defensivas de SSH
PROXY_CMD="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o LogLevel=ERROR -W %h:%p -p 22 ${BASTION_USER_HOST}"

SSH_BASE_ARGS=(
    -i "${SSH_KEY}"
    -o "IdentitiesOnly=yes"
    -o "StrictHostKeyChecking=accept-new"
    -o "UserKnownHostsFile=/dev/null"
    -o "ConnectTimeout=10"
    -o "ServerAliveInterval=30"
    -o "ServerAliveCountMax=3"
    -o "LogLevel=ERROR"
    -o "ProxyCommand=${PROXY_CMD}"
)

# 2. Testar conectividade com retry loop para absorver eventuais atrasos de propagação da chave
echo "🔍 Validando autenticação e conectividade com ${TARGET}..."
MAX_PROBE_RETRIES=5
PROBE_DELAY=3
CONNECTED=0

for ((attempt=1; attempt<=MAX_PROBE_RETRIES; attempt++)); do
    if ssh "${SSH_BASE_ARGS[@]}" -o BatchMode=yes "ubuntu@${TARGET_IP}" "true" 2>/dev/null; then
        CONNECTED=1
        break
    fi
    echo "⏳ Chave em processo de autorização pelo Bastion... Tentativa ${attempt}/${MAX_PROBE_RETRIES}. Aguardando ${PROBE_DELAY}s..."
    sleep "${PROBE_DELAY}"
done

# Se a sessão reaproveitada falhou após os retries, invalida e recria uma sessão limpa
if [[ "${CONNECTED}" -ne 1 && "${IS_REUSED_SESSION}" -eq 1 ]]; then
    echo "⚠️ A sessão reaproveitada não respondeu à autenticação da chave. Criando uma sessão nova e limpa..."
    SESSION_ID=$(create_bastion_session "${TARGET_IP}")
    BASTION_USER_HOST=$(get_bastion_host "${SESSION_ID}")
    PROXY_CMD="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o LogLevel=ERROR -W %h:%p -p 22 ${BASTION_USER_HOST}"
    SSH_BASE_ARGS=(
        -i "${SSH_KEY}"
        -o "IdentitiesOnly=yes"
        -o "StrictHostKeyChecking=accept-new"
        -o "UserKnownHostsFile=/dev/null"
        -o "ConnectTimeout=10"
        -o "ServerAliveInterval=30"
        -o "ServerAliveCountMax=3"
        -o "LogLevel=ERROR"
        -o "ProxyCommand=${PROXY_CMD}"
    )

    for ((attempt=1; attempt<=MAX_PROBE_RETRIES; attempt++)); do
        if ssh "${SSH_BASE_ARGS[@]}" -o BatchMode=yes "ubuntu@${TARGET_IP}" "true" 2>/dev/null; then
            CONNECTED=1
            break
        fi
        echo "⏳ Aguardando autorização da chave na nova sessão... Tentativa ${attempt}/${MAX_PROBE_RETRIES}. Aguardando ${PROBE_DELAY}s..."
        sleep "${PROBE_DELAY}"
    done
fi

if [[ "${CONNECTED}" -ne 1 ]]; then
    echo "❌ Erro: Não foi possível autenticar via chave SSH após múltiplas tentativas."
    echo "💡 Verifique se sua chave pública está autorizada na instância de destino (${TARGET_IP})."
    exit 1
fi

echo "✅ Autenticação confirmada!"

# 3. Execução do comando ou início da sessão interativa
if [[ $# -gt 0 ]]; then
    echo "▶️ Executando comando remoto..."
    exec ssh "${SSH_BASE_ARGS[@]}" "ubuntu@${TARGET_IP}" "$@"
else
    echo "✨ Sessão interativa iniciada em ${TARGET} (digite 'exit' para sair):"
    exec ssh "${SSH_BASE_ARGS[@]}" "ubuntu@${TARGET_IP}"
fi
